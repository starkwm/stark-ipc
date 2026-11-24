TEST_ARGS ?=

format:
	@swift format format -r -i Sources Tests Package.swift

lint:
	@swift format lint --strict -r Sources Tests Package.swift

test:
	@swift test --no-parallel --disable-xctest $(TEST_ARGS)

.DEFAULT_GOAL := lint
.PHONY: format lint test
