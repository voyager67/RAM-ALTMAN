# Testing

All tests are offline. The supplied regression suite creates a synthetic `/proc/meminfo` file and places a fake `sendmail` executable earlier in `PATH`. The extended suite also places a fake `curl` executable in `PATH` to capture webhook requests without contacting an external service.

Run both suites:

```bash
make test
```

Or individually:

```bash
./test-ram-sentinel.sh
./tests/test-ram-sentinel-extended.sh
```

The main suite has 15 assertions. The extended suite has 12 assertions for JSON counters, webhook-only mode, Slack/Discord payload shapes, per-day webhook limits, report statistics, dry-run privacy, log rotation and rejection of insecure webhook URLs.
