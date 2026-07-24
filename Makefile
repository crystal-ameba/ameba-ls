CRYSTAL_FILES := $(shell find src -type f -name '*.cr')

.PHONY: ameba-ls
ameba-ls: ./bin/ameba-ls

./bin/ameba-ls: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build ameba-ls -p -s --release
