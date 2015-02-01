DC = dmd

findup: *.d
	$(DC) -debug -w -wi -of$@ $^

clean:
	rm *.o findup

.PHONY: clean
