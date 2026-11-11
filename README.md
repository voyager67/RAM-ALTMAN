# Ram-Sentinel

**A production-grade bash script that writes to Sam Altman once a day to report the RAM he missed.**

[![Global DRAM allocation: quite terrible](https://img.shields.io/badge/global%20DRAM%20allocation-quite%20terrible-red)](#)
[![Utilization: maybe 5%](https://img.shields.io/badge/utilization-maybe%205%25-orange)](#)
[![Emails: 1 per day](https://img.shields.io/badge/emails-1%20per%20day-blue)](#)
[![Written in Bash, not Electron](https://img.shields.io/badge/written%20in-bash%2C%20not%20electron-brightgreen)](#)

There is RAM in your computer. Right now. Just sitting there, in a *personal* computer, being personal.

You may have thought of this as "a computer working normally". On a recent episode of Cheeky Pint, the CEO of OpenAI offered another view:

> "From a global allocation perspective, actually, it's quite terrible to have everybody have a bunch of the world's limited supply of DRAM sitting in their own computer"
>
> — Sam Altman

That RAM, he added, is "being used maybe 5% of the time".

Which raised an obvious question for a certain kind of person: *surely someone should be monitoring this properly?*

So we wrote a script. If your machine has more than 10% of its RAM available, it sends one carefully composed email a day to let Sam know. It seemed only fair. He can't fix the problem if nobody tells him where the RAM is.

## Features

- Accurate memory accounting using `MemAvailable` (with a sensible fallback for older kernels)
- Tracks total, used, available, free, cache and swap
- Sends at most one email per day — we're hoarders, not animals
- Rotates 12 subject lines, 12 message bodies and 8 sign-offs so the joke ages at a carefully managed pace
- Logs every sample to CSV for when the auditors (or the curious) arrive
- Optional webhook support (Slack, Discord, Mattermost, etc.)
- Built-in report mode for quick utilisation summaries
- Proper locking, soft log rotation and retry-on-failure behaviour
- Ships with a full test suite that never touches a real inbox
- Written in pure bash, because an Electron version would have solved the problem by consuming all the RAM

## A sample of today's correspondence

```text
Subject: You missed a spot

Hi Sam,

Please do not be alarmed, but there is 8.6 GiB of RAM on my desk that is not in
a data centre. That is 56.2% of what is installed here, and as far as I can tell
it has no plans today.

Hoarding responsibly,
A concerned RAM owner

--
Sent automatically, at most once a day, by a small script on one machine.
Reply if you would like it to stop.
```

The figures are real. They come from your machine. That's the worrying part.

## What counts as "used"?

```text
used = MemTotal - MemAvailable
```

`MemAvailable` is the kernel's own estimate of how much memory programs could claim without swapping. Free RAM counts as available. So does cache the kernel can reclaim. tmpfs and shared memory do not, because they cannot simply be handed back.

Every sysadmin has spent years explaining that [Linux didn't eat your RAM](https://www.linuxatemyram.com/) and that free RAM is wasted RAM. It took decades for someone important to agree with the second part, and he'd like it shipped to him.

Strictly speaking, the page cache is doing useful work, so counting it as available is a generous concession to the other side. Think of it as a plea bargain.

On kernels older than 3.14 (no `MemAvailable`), the script estimates available memory from free + reclaimable cache. If you're still on one of those, your RAM may be safe. Nobody is coming for it.

## Installation

You'll need Linux, bash, `awk`, standard core utilities, `flock`, and a working `sendmail`, `msmtp` or `mail` command for email delivery. Webhook delivery additionally requires `curl`. Your RAM is assumed.

```bash
git clone https://github.com/YOUR_USERNAME/ram-sentinel.git
cd ram-sentinel
chmod +x ram-sentinel.sh test-ram-sentinel.sh tests/test-ram-sentinel-extended.sh

./ram-sentinel.sh --status    # see the evidence against you
./ram-sentinel.sh --dry-run   # preview an email without sending it
./ram-sentinel.sh --report    # summary of recent samples (after it has run a while)
./ram-sentinel.sh --json      # machine-readable RAM and swap statistics
```

Example output (illustrative values):

```text
RAM Sentinel 1.0.0
----------------------------------------
Total:      15.3 GiB
Used:       6.7 GiB (43.8%)
Available:  8.6 GiB (56.2%)
  Free:     0.3 GiB
  Cache:    8.2 GiB
Swap:       0.0 GiB used of 0.0 GiB (0.0%)
Threshold:  crossed (> 10% available)
```

## Send the daily report

RAM Sentinel does not ship with a recipient address. Configure a sender and a recipient you control, or a recipient who has explicitly agreed to receive the parody. A local mail transport must already be configured.

```bash
export RAM_SENTINEL_TO="you@example.com"
export RAM_SENTINEL_FROM="ram-sentinel@example.com"
export RAM_SENTINEL_FROM_NAME="A Concerned RAM Owner"
export RAM_SENTINEL_THRESHOLD="10"

./ram-sentinel.sh --dry-run
```

The dry run previews the email and does not send it or create the state directory. When the preview looks right, add a cron entry with `crontab -e`:

```cron
*/5 * * * * RAM_SENTINEL_TO="you@example.com" RAM_SENTINEL_FROM="ram-sentinel@example.com" /absolute/path/to/ram-sentinel/ram-sentinel.sh
```

The script samples every five minutes and sends at most one successful report per local calendar day, provided available RAM is **strictly greater** than the configured threshold. At exactly 10%, a 10% threshold does not trigger. If delivery fails, the date is not recorded and a later run can retry.

### Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `RAM_SENTINEL_TO` | Recipient address; required for email delivery. | Unset |
| `RAM_SENTINEL_FROM` | Sender address accepted by the mail transport. | Unset |
| `RAM_SENTINEL_FROM_NAME` | Optional sender display name. Newlines are rejected. | Unset |
| `RAM_SENTINEL_THRESHOLD` | Report when available RAM is above this whole-number percentage (0–100). | `10` |
| `RAM_SENTINEL_STATE_DIR` | Directory for CSV history, rotation bags, lock and daily state. | `~/.local/state/ram-sentinel` |
| `RAM_SENTINEL_MEMINFO` | Alternate meminfo path, primarily for tests. | `/proc/meminfo` |
| `RAM_SENTINEL_WEBHOOK` | Optional HTTPS incoming webhook URL. | Unset |
| `RAM_SENTINEL_WEBHOOK_FORMAT` | `slack` (`text`) or `discord` (`content`) JSON payload. | `slack` |
| `RAM_SENTINEL_WEBHOOK_TIMEOUT` | Maximum seconds to wait for a webhook response. | `10` |
| `RAM_SENTINEL_LOG_LIMIT_BYTES` | Soft CSV rotation threshold. | `20971520` (20 MiB) |
| `RAM_SENTINEL_LOG_KEEP_ROWS` | Recent data rows retained after rotation. | `100000` |
| `RAM_SENTINEL_LOCK_TIMEOUT` | Seconds to wait for the scheduled-run lock. | `5` |

## Optional webhook support

The default webhook format is Slack-style. For a Discord incoming webhook, choose the `content` payload:

```bash
export RAM_SENTINEL_WEBHOOK="https://hooks.example.invalid/your-private-hook"
export RAM_SENTINEL_WEBHOOK_FORMAT="discord" # or slack

./ram-sentinel.sh --dry-run
```

Webhook delivery requires `curl`. The dry run never contacts the endpoint and never prints the webhook URL. Keep webhook URLs private; they are credentials and must not be committed to Git.

You can configure email, a webhook, or both. When both are configured, the script attempts both before recording the date as sent. If one succeeds and the other fails, the next scheduled run may repeat the successful channel. Configure only the notification channels you intend to use.

## Audit yourself

Let the script collect samples, then inspect the local history:

```bash
./ram-sentinel.sh --report
```

The report includes sample count, first and latest sample, average and peak RAM utilisation, available-memory range, and average and peak swap utilisation. It reads the local CSV file; nothing is uploaded to a telemetry service.

## Testing

The main regression suite uses simulated `/proc/meminfo` data and a fake `sendmail`. It does not contact an external mail server.

```bash
bash -n ram-sentinel.sh test-ram-sentinel.sh tests/test-ram-sentinel-extended.sh
./test-ram-sentinel.sh
./tests/test-ram-sentinel-extended.sh
```

The supplied regression suite contains 15 checks. The additional suite exercises JSON swap output, Slack and Discord webhook payloads, webhook-only delivery, the daily cap, report output, dry-run privacy, CSV rotation and HTTPS validation.

## Please be a good neighbour

One parody report a day to an address you control is a joke. A large number of unsolicited messages is not.

- **Use a recipient who has agreed to receive it.** Do not configure a real person's private address without permission.
- **Start with `--dry-run`.** It previews the message without sending mail or contacting a webhook.
- **Do not deploy this across a server fleet to multiply the volume.**
- **Keep webhook URLs and mail credentials out of the repository.**
- **If a recipient asks you to stop, stop.**

The default configuration sends nothing. The operator is responsible for the configured recipient, mail transport and webhook endpoint.

## In fairness to Sam

The comments that inspired the joke were made during a discussion of global DRAM supply and the relative utilisation of consumer and data-centre memory. The parody is not a technical claim that desktop RAM is literally available to data centres, nor does a point-in-time availability sample measure the percentage of time memory is actively used.

The script measures the kernel's current memory accounting and turns an ordinary status report into an unnecessarily formal piece of correspondence. The accounting is serious. The recipient premise is not.

## Project lineage

RAM Sentinel is an independent implementation of the premise. It was inspired by [Iain Kay's `ram-altman`](https://github.com/IainKay/ram-altman), whose repository is released under The Unlicense. This project is not affiliated with Iain Kay or OpenAI and is not an official OpenAI tool.

## License

Released under the Unlicense (public domain). See [LICENSE](LICENSE).
