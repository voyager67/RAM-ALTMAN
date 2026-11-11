.PHONY: test syntax status preview report

syntax:
	bash -n ram-sentinel.sh test-ram-sentinel.sh tests/*.sh

test: syntax
	./test-ram-sentinel.sh
	./tests/test-ram-sentinel-extended.sh

status:
	./ram-sentinel.sh --status

preview:
	./ram-sentinel.sh --dry-run

report:
	./ram-sentinel.sh --report
