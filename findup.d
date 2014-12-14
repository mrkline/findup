import std.container;
import std.stdio;
import std.file;
import std.digest.sha;

// We use these variables absolutely everywhere and their lifetime
// is that of the program, so just make them global.
SizeMatch[ulong] sizeMatches;
Array!DirEntry[SHA1Hash] hashMatches;

/**
 * For each entry in the matching sizes hash table,
 * we need to keep track of the first file with a matching size.
 * Then, if we get a second file with the same size,
 * we can SHA1 the first match as well as our new one.
 * We'll then set "hashed" to true, so we know not to re-SHA1
 * the first one.
 *
 */
struct SizeMatch {
	DirEntry firstWithMatchingSize;
	bool hashed = false;

	@disable this();

	this(DirEntry e) { firstWithMatchingSize = e; }
}

alias ubyte[20] SHA1Hash;

void main(string[] args)
{
	// Shave off our path
	args = args[1 .. $];

	foreach (string arg; args)
		scan(arg);

	printResults();
}

// Scan a directory or a file
void scan(string path)
{
	auto entry = DirEntry(path);

	if (entry.isFile)
		compareAndInsert(entry);
	else if (entry.isDir)
		scanRecurser(entry);
	else
		stderr.writeln("findup was given (and is ignoring) the special file ", entry.name);
}

void scanRecurser(DirEntry dir)
{
	foreach (DirEntry entry; dirEntries(dir.name, SpanMode.shallow, false)) {
		if (entry.isFile)
			compareAndInsert(entry);
		else if (entry.isDir && !entry.isSymlink)
			scanRecurser(entry);
	}
}

void compareAndInsert(ref DirEntry entry)
in
{
	assert(entry.isFile);
}
body
{
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
		foreach (ubyte[] chunk; chunks(File(toHash.name), 4096)) {
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

void printResults()
{
	// The comparer never writes a newline (just \r),
	// so make sure we write at least one before we leave;
	bool matchesFound = false;

	foreach (matches; hashMatches.values()) {
		if (matches.length < 2)
			continue;

		matchesFound = true;

		foreach(DirEntry match; matches) {
			writeln(match.name);
		}
		writeln();
	}

	if (!matchesFound)
		stderr.writeln("\nNo matches found");
	else
		// The progress indicator never prints a newline. Do so before we leave
		stderr.writeln();
}
