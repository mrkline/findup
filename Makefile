DC = dmd
DFLAGS = -wi -wi

all: debug

debug: DFLAGS += -debug -unittest -g
debug: findup

release: DFLAGS += -O -release
release: findup

findup: findup.d
	$(DC) $(DFLAGS) -of$@ $^

clean:
	rm -f *.o findup

.PHONY: all debug release clean
