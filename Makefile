.PHONY: lint

lint:
	forge fmt --check
	solhint -c .solhint.json --max-warnings 0 "src/**/*.sol"
	solhint -c script/.solhint.json --max-warnings 0 "script/**/*.sol"
	#solhint -c test/.solhint.json --max-warnings 0 "test/**/*.t.sol"
