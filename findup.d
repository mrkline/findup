import std.algorithm;
import std.container;
import std.conv;
import std.digest.sha;
import std.exception;
import std.file;
import std.range;
import std.regex;
import std.stdio;
import std.string;

/// SHA1 hashes are 20 bytes long
alias ubyte[20] SHA1Hash;

/**
 * For each entry in the matching sizes hash table,
 * we need to keep track of the first file with a matching size.
 * Then, if we get a second file with the same size,
 * we can SHA1 the first match as well as our new one.
 * We'll then set "hashed" to true, so we know not to re-SHA1
 * the first one.
 */
struct SizeMatch {
	DirEntry firstWithMatchingSize;
	bool hashed = false;

	@disable this();

	this(DirEntry e) { firstWithMatchingSize = e; }
}

/// Used to indicate the size operator.
enum SizeOperator {
	greater,
	less,
	equal
};

// We use these variables absolutely everywhere and their lifetime
// is that of the program, so just make them global.

// By default, have no min and max depth and search files of all sizes.
int mindepth = 0;
int maxdepth = int.max;
ulong searchSize = 0;
SizeOperator sizeOp = SizeOperator.greater;

SizeMatch[ulong] sizeMatches;
Array!DirEntry[SHA1Hash] hashMatches;

void main(string[] args)
{
	import std.getopt;
	import std.c.stdlib;

	string sizeArg;
	bool printNull;

	getopt(args,
		std.getopt.config.caseSensitive,
		"help|h", { writeln(helpText); exit(0); },
		"version|v", { writeln(versionText); exit(0); },
		"mindepth", &mindepth,
		"maxdepth", &maxdepth,
		"size", &sizeArg,
		"null|0", &printNull);

	if (mindepth < 0 || maxdepth < 0) {
		stderr.writeln("A depth cannot be negative.");
		exit(1);
	}

	if (maxdepth < mindepth) {
		stderr.writeln("The max depth cannot be less than the min depth.");
		exit(1);
	}

	if (!sizeArg.empty) {
		enum sizeRegex = ctRegex!`^([+-]?)(\d+)([bcwkMG]?)$`;

		auto captures = sizeArg.matchFirst(sizeRegex);

		if (!captures) {
			stderr.writeln("The --size argument is not in the correct format.");
			stderr.writeln("See findup --help for details.");
			exit(1);
		}

		if (captures[1].empty) {
			sizeOp = SizeOperator.equal;
		}
		else if (captures[1] == "+")
			sizeOp = SizeOperator.greater;
		else if (captures[1] == "-")
			sizeOp = SizeOperator.less;
		else
			assert(false); // Nothing else should get past the regex.

		searchSize = captures[2].to!ulong;

		if (captures[3]) {
			switch(captures[3]) {
				case "b": // blocks
					searchSize *= 512;
					break;

				case "c": // Bytes ("chars"?)
					break;

				case "w": // two-byte words
					searchSize *= 2;
					break;

				case "k": // kB
					searchSize *= 1024;
					break;

				case "M": // Megabyte
					searchSize *= 1024 * 1024;
					break;

				case "G": // Gigabyte
					searchSize *= 1024 * 1024 * 1024;
					break;

				default:
					assert(false);
			}
		}
	}

	// Shave off our the path through which we were executed.
	args = args[1 .. $];

	// If we don't specify a directory, read from stdin
	if (args.empty) {
		foreach (inLine; stdin.byLine(KeepTerminator.no, printNull ? '\0' : '\n')) {
			auto entry = DirEntry(strip(inLine).idup);
			if (entry.isFile)
				compareAndInsert(entry);
		}
	}
	else {
		foreach (string arg; args)
			scan(arg);
	}

	printResults();
}

string helpText = q"EOS
Usage: findup [--mindepth <depth>] [--maxdepth <depth>] [--size <size>] [<paths>]

Searches <paths> for duplicate files, checking first by size, then, if files
match in size, by SHA1 hash. The likelihood of two files having the same SHA1
is something like 1 in 2^50, even with the birthday paradox taken into
consideration, so for now there are no checks of the actual file contents if
hashes _and_ sizes match.  A flag will probably be added at some point in the
future if you want to be really sure.

If no paths are provided, paths are read from stdin on a line by line basis.

Options:

  --help, -h
    Display this help text and exit.

  --version, -v
    Display version information and exit.

  --mindepth <depth>
    Do not consider files at levels less than <depth> (a non-negative integer).
    --mindepth 0 includes any files provided as command line arguments,
    whereas --mindepth 1 will skip any files and only search the directories
    provided as command line arguments.

  --maxdepth <depth>
    Do not consider files at levels greater than <depth>
    (an integer greater than or equal to the minimum depth or 0,
    whichever is larger). --maxdepth 0 means to only check any files provided
    as command line arguments and ignore any provided directories.

  --size <size>
    Only consider files of a given size or range of sizes.
    <size> is provided as [+/-]n[cwbkMG].
    A leading + indicates to only consider files greater than the size.
    A leading - indicates to only consider files less than the size.
    No leading + or - indicates to only consider files of that exact size.
    Suffixes denote the unit of n:
    'b' for 512-byte blocks (this is the default if no suffix is used)
    'c' for bytes
    'w' for two-byte words
    'k' for Kilobytes (units of 1024 bytes)
    'M' for Megabytes (units of 1048576 bytes)
    'G' for Gigabytes (units of 1073741824 bytes)
    These suffixes might be somewhat odd, but match POSIX 'find'.

  --null, -0
    If paths are provided via stdin, assume they are separated by a null
    character instead of by newline. This is similar to the xargs option
    of the same name, though it may be needed less often as findup separates
    input paths by line and not by any whitespace like xargs does.
EOS";

string versionText = q"EOS
findup, version 0.1.0
by Matt Kline, 2014
EOS";

// Scan a directory or a file
void scan(string path)
{
	auto entry = DirEntry(path);

	if (entry.isFile && mindepth == 0)
		compareAndInsert(entry);
	else if (entry.isDir && maxdepth > 0)
		scanRecurser(entry, 1);
	else
		stderr.writeln("findup was given (and is ignoring) the special file ", entry.name);
}

void scanRecurser(DirEntry dir, int depth)
in
{
	assert(dir.isDir);
	assert(depth >= 0);
}
body
{
	foreach (DirEntry entry; dirEntries(dir.name, SpanMode.shallow, false)) {
		if (entry.isFile)
			compareAndInsert(entry);
		else if (entry.isDir && !entry.isSymlink && maxdepth > depth)
			scanRecurser(entry, depth + 1);
	}
}

void compareAndInsert(ref DirEntry entry)
in
{
	assert(entry.isFile);
}
body
{
	if (!shouldConsiderFile(entry)) {
		return;
	}

	static ulong count = 0;
	stderr.write("\rComparing file number ", ++count);

	auto sizeMatch = entry.size in sizeMatches;

	// If its size is unique, Add it to the list of unique sizes and go away.
	if (!sizeMatch) {
		sizeMatches[entry.size] = SizeMatch(entry);
		return;
	}

	// Let's take a second to add a convenince function (in a function)
	// to SHA1 a file and insert it into our hashMatches list
	void hashAndInsert(ref DirEntry toHash)
	{
		SHA1 hasher;
		File fh;
		try {
			fh = File(toHash.name);
		}
		catch (ErrnoException) {
			// The file isn't here anymore apparently.
			// Move along.
			return;
		}
		foreach (ubyte[] chunk; chunks(fh, 4096)) {
			hasher.put(chunk);
		}
		SHA1Hash resultingHash = hasher.finish();

		auto hashMatch = resultingHash in hashMatches;
		if (!hashMatch) {
			hashMatches[resultingHash] = Array!DirEntry();
			hashMatches[resultingHash].insertBack(toHash);
		}
		else {
			hashMatch.insertBack(toHash);
		}
	}

	// Okay, at least one other file has the same size.
	// Has it been SHA1'd already?
	if (!sizeMatch.hashed) {
		// Nope. Let's do that.
		hashAndInsert(sizeMatch.firstWithMatchingSize);
		sizeMatch.hashed = true;
	}

	// Back to our regular scheduled broadcast.
	// Insert the entry we were looking at.
	hashAndInsert(entry);
}

bool shouldConsiderFile(DirEntry e)
in
{
	assert(e.isFile);
}
body
{
	if (sizeOp == SizeOperator.greater)
		return e.size >= searchSize;
	else if (sizeOp == SizeOperator.less)
		return e.size <= searchSize;
	else if (sizeOp == SizeOperator.equal)
		return e.size == searchSize;
	else // There shouldn't be anything else
		assert(false);
}

void printResults()
{
	// The comparer never writes a newline (just \r),
	// so make sure we write at least one before we leave;
	auto duplicates = hashMatches.values().filter!(m => m.length > 1);

	if (duplicates.empty)
		stderr.writeln("\nNo duplicates found");
	else
		// The progress indicator never prints a newline. Do so before we leave
		stderr.writeln();

	foreach (set; duplicates) {
		foreach(DirEntry match; set) {
			writeln(match.name);
		}
		writeln();
	}
}
