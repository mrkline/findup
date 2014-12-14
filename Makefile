
findup: *.d
	dmd -debug -w -wi -of$@ $^

clean:
	rm *.o findup

.PHONY: clean
