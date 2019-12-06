.PHONY: all

SRC_FILES = -Isource/ source/mempooled/*.d
BUILD_FLAGS = -debug -g -w -vcolumns
TEST_FLAGS = $(BUILD_FLAGS) -unittest

ifeq ($(DC),ldc2)
	DC=ldmd2
endif

all: build

build:
	$(DC) -of=mempooled -lib $(BUILD_FLAGS) $(SRC_FILES)

buildTest:
	$(DC) -of=mempooled-test -main $(TEST_FLAGS) $(SRC_FILES)

test: buildTest
	./mempooled-test

buildBC:
	$(DC) -of=mempooled -betterC -lib $(BUILD_FLAGS) $(SRC_FILES)

buildTestBC:
	$(DC) -of=mempooled-test-bc -betterC $(TEST_FLAGS) $(SRC_FILES)

testBC: buildTestBC
	./mempooled-test-bc

buildCov: $(SILLY_DIR)
	$(DC) -of=mempooled-test-codecov -cov -main $(TEST_FLAGS) $(SRC_FILES)

codecov: buildCov
	./mempooled-test-codecov

clean:
	- rm -f *.a
	- rm -f *.o
	- rm -f mempooled-test*
	- rm -f ./*.lst
