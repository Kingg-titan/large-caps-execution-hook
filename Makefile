.PHONY: bootstrap build test coverage fmt lint export-shared demo-local demo-compare demo-testnet verify-commits verify-deps

bootstrap:
	./scripts/bootstrap.sh

build:
	forge build

fmt:
	forge fmt

lint:
	forge fmt --check

test:
	forge test -vv

coverage:
	forge coverage --report summary

export-shared:
	./scripts/export-shared.sh

demo-local:
	forge script script/10_DemoCompareLocal.s.sol:DemoCompareLocalScript --rpc-url $${ANVIL_RPC_URL:-http://127.0.0.1:8545} --broadcast -vvv

demo-compare: demo-local

demo-testnet:
	forge script script/00_DeployLargeCapSystem.s.sol:DeployLargeCapSystemScript --rpc-url "$${TESTNET_RPC_URL}" --broadcast --verify -vvv

verify-deps:
	./scripts/bootstrap.sh

verify-commits:
	./scripts/verify_commits.sh
