.PHONY: lint static-analysis coverage build test

lint:
	@test -x node_modules/.bin/solhint || (echo "solhint not installed - run 'npm ci' first" && exit 1)
	forge fmt --check
	CI=true npx --no-install solhint -c .solhint.json --max-warnings 0 "src/**/*.sol"
	CI=true npx --no-install solhint -c script/.solhint.json --max-warnings 0 "script/**/*.sol"
	#CI=true npx --no-install solhint -c test/.solhint.json --max-warnings 0 "test/**/*.t.sol"

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
	