.PHONY: lint static-analysis coverage build test

lint:
	@test -x node_modules/.bin/solhint || (echo "solhint 6.2.3 not installed - run 'npm ci' first" && exit 1)
	forge fmt --check
	npx --no-install solhint -c .solhint.json --max-warnings 0 "src/**/*.sol"
	npx --no-install solhint -c script/.solhint.json --max-warnings 0 "script/**/*.sol"
	#npx --no-install solhint -c test/.solhint.json --max-warnings 0 "test/**/*.t.sol"

static-analysis:
	@command -v slither >/dev/null 2>&1 || (echo "slither not installed - pipx install slither-analyzer" && exit 1)
	forge build --build-info --skip test script
	slither .

coverage: 
	forge coverage

build:
	forge build

test:
	forge test
	