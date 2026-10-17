# MacRazer reports Worker

The device test's **Send** button posts its report here. This Cloudflare Worker checks the
report, emails it to the maintainer, and keeps nothing. The only stored data is a count of
reports per day, used for the caps below.

It also takes the app's opt-in usage stats. See [Usage stats](#usage-stats) below.

## What it accepts

`POST /v1/device-report` with `Content-Type: application/json`, at most 16 KB. The report must
match the app's format exactly ([src/validate.ts](src/validate.ts)). An unknown field, a value
out of range, a vendor other than Razer, or a line break in the reply address gets it refused.
Text that comes from the mouse rather than the person, like product names and error messages,
is cleaned of control characters and cut to length instead, so one odd byte doesn't lose a
report. The email is built from the checked fields only. Its subject comes from the step
results, not from anything the request claims.

| Status | Meaning | What the app says |
|---|---|---|
| 200 | Emailed | Thank you, plus what the report means for this mouse |
| 400, 404, 405, 413, 415 | Refused | Open a GitHub issue instead |
| 429 | Too many: 3 a minute or 10 a day from one IP, or 50 a day in total | Try again tomorrow |
| 503 | Not set up right, or the email didn't go | Try again later |

## What it keeps

- **Counters only**, in D1: one row per day for the total, and one per sender. A sender is a
  SHA-256 hash of the IP address with a secret salt and the date, so the table can't be matched
  against a list of addresses, and the same IP looks different every day. Rows go after two days.
  The burst limiter is given the same hash, never the address. A report that fails to send
  isn't counted.
- **No report content.** The report exists in memory long enough to build the email.
- On success the Worker logs the mouse's product ID. On failure it logs the email service's
  error code. Nothing else is logged.

## Usage stats

Only from people who clicked Share in the app ([src/stats.ts](src/stats.ts)).

| Request | What it does |
|---|---|
| `POST /v1/stats` | A ping: the Mac's ID, app and macOS versions, chip, and up to 4 connected mice. At most 4 KB. |
| `DELETE /v1/stats/<id>` | Delete My Data. Answers 200 whether or not the ID was known. |

**What's kept**, in D1 ([migrations/0002_usage_stats.sql](migrations/0002_usage_stats.sql)):

- `installs`: one row per Mac. The ID, first and last day seen, the latest versions and chip,
  and how many times it was reinstalled. The ID is the app's keyed hash of the hardware UUID.
  It can't be turned back into the UUID or the serial number.
- `install_mice`: each mouse a Mac reported, by product ID and link (wired, 2.4 GHz,
  Bluetooth), with its name and whether MacRazer supports it. At most 16 per Mac.
- `deleted_installs` and `deleted_mice`: what Delete My Data leaves. The same details without
  the ID, in two tables that aren't linked to each other, so nothing there leads back to a Mac.
  The mice are dated only to the month, so a quiet day's deletion can't be matched up by date.
- Days only, never times. No IP addresses. Nothing is logged about a ping.

**Limits.** 10 requests a minute from one IP (`STATS_BURST`). New Macs are capped per day, at
20 per IP and 2000 in total (`DAILY_NEW_PER_IP`, `DAILY_NEW_TOTAL`), so junk can't grow the
tables fast. A Mac already known is never turned away by those. All pings together stop at
10,000 a day (`DAILY_STATS_TOTAL`), so stats can't use up the D1 writes the device reports
need too. Deletions are never capped.

**Reading it.** `npm run stats` prints a summary: Macs, versions, mice (unsupported ones are
the ones to add next), macOS, chip, and deletions. `npm run stats:local` reads the local
database `wrangler dev` uses.

## Setup

You need a Cloudflare account with a domain on it. Sending to your own verified address is
free on every plan. An account you use for other projects is fine: this is one more Worker and
one more database, with names of their own.

Nothing private goes in the repository. [wrangler.toml](wrangler.toml) is a public
template with placeholders. Your four private values live in a settings file outside the
repository, `~/.config/macrazer-reports/settings.env`, so every checkout and worktree uses the
same one and it can't be committed. Each `npm run` command below first builds the real config,
`wrangler.local.toml`, from the template plus that file. Git ignores the result, and it's
rebuilt every time, so a change to the template is never left out of a deploy.

1. Install the tools and log in:

   ```sh
   cd worker
   npm install
   npx wrangler login
   ```

2. In the Cloudflare dashboard, enable **Email Routing** on your domain. Under destination
   addresses, add the address reports should go to, then click the link in the verification
   email. Enabling it replaces the domain's MX records, so use a domain that doesn't already
   receive email elsewhere.

3. Create the database. It prints a `database_id`. If Wrangler offers to add the database to
   your config, say no: the id goes in your settings file instead.

   ```sh
   npx wrangler d1 create macrazer-reports
   ```

4. Create `~/.config/macrazer-reports/settings.env` with your four values:

   ```sh
   DESTINATION=you@yourdomain.com
   SENDER=macrazer-reports@yourdomain.com
   DATABASE_ID=the-id-from-step-3
   DOMAIN=macrazer.yourdomain.com
   ```

   - `DESTINATION`: the address you verified in step 2. It goes in both `destination_address`,
     which locks the binding to it, and `DESTINATION_ADDRESS`, which the Worker sends to.
   - `SENDER`: any address on the Email Routing domain. It doesn't need a mailbox.
   - `DOMAIN`: the hostname the Worker answers on, on a domain in this Cloudflare account.
     Deploying creates its DNS record and certificate. It doesn't need to be the Email Routing
     domain, and no other site may already use that exact name. There is no `workers.dev`
     address: see [Protecting it](#protecting-it).
   - `Scripts/build-app.sh` reads `DOMAIN` from this file too, and writes
     `https://<DOMAIN>` into the app it builds. A build without this file has no Worker, and
     hides Send and the usage stats.
   - To keep the file somewhere else, set `MACRAZER_REPORTS_SETTINGS` to its path.

5. Create the tables, then deploy:

   ```sh
   npm run migrate
   npm run deploy
   ```

   Already set up from before the usage stats? `npm run migrate` again adds their tables. It
   only applies the migrations the database doesn't have yet.

   Always deploy with `npm run deploy`. A plain `npx wrangler deploy` reads the template, with
   its placeholder addresses.

6. Set the salt for the IP hashes, a random secret you never need to see:

   ```sh
   npm run salt
   ```

   Until it's set, the Worker answers every report with a 503 and sends nothing.

7. Send a test report. A 200 here should arrive as an email, maybe in spam the first time:

   ```sh
   curl -i https://macrazer.yourdomain.com/v1/device-report \
     -H 'content-type: application/json' --data @test/fixtures/full-report.json
   ```

   A 503 means a step above is missing. `npm run tail` shows why, for example
   `E_SENDER_NOT_VERIFIED` when the sender's domain doesn't have Email Routing.

   Then a test ping, and take it out again (it's not a real Mac):

   ```sh
   curl -i https://macrazer.yourdomain.com/v1/stats \
     -H 'content-type: application/json' --data @test/fixtures/usage-ping.json
   npm run stats
   curl -i -X DELETE https://macrazer.yourdomain.com/v1/stats/3f9a0c71e2b84d6a9c15e0b7d4a2f816
   ```

8. Add the rate-limiting rule in [Protecting it](#protecting-it).

9. Build the app with `./Scripts/build-app.sh`. It should print `Worker: https://…`.
   `Scripts/release.sh` refuses to finish a release whose app has no Worker address.

## Protecting it

Cloudflare drops network floods for every plan on its own. What's left is someone sending
lots of real-looking requests from many addresses. Three layers deal with that:

- **A WAF rate-limiting rule, in front of the Worker.** It turns a flood away before the
  Worker runs, so the requests don't count toward the account's daily Worker allowance, which
  every Worker on the account shares. The Free plan includes one rule. In the dashboard, on
  the domain: **Security › WAF › Rate limiting rules › Create rule**:
  - If incoming requests match: Hostname equals your `DOMAIN`, and URI Path starts with `/v1/`
  - With the same characteristics: IP
  - When rate exceeds: 20 requests per 10 seconds
  - Then: Block, for 10 seconds

  The app sends one or two requests at launch, so no real person gets near that.
  This only works because the Worker has no `workers.dev` address (`workers_dev = false`),
  which would be a way round the rule.
- **The Worker's own limits:** the per-IP burst limiters and the daily caps above. A request
  over a daily cap is answered after a read, with nothing written, so a flood can't use up
  D1's daily writes either.
- **The Free plan.** Going over a limit there makes requests fail until the next UTC day.
  You're never billed for it. On the Paid plan there's no such ceiling, so set a budget alert
  before you move.

Nothing here can stop made-up stats: the app is open source, so it holds no secret to prove a
ping is real. The caps keep that small, and `npm run stats` should be read with it in mind.

## Changing where reports go

Verify the new address in Email Routing first. Then change `DESTINATION` in your settings file
and run `npm run deploy`. The binding can't send anywhere but that address, whatever a request
says. The Worker never takes an address from the request.

## Changing the caps

- Per day: `DAILY_PER_IP`, `DAILY_TOTAL`, `DAILY_NEW_PER_IP`, `DAILY_NEW_TOTAL` and
  `DAILY_STATS_TOTAL` in `wrangler.toml`. They aren't private, so they live in the template.
- Per minute: `limit` under `[[ratelimits]]`. Cloudflare only allows a `period` of 10 or 60
  seconds, and counts per location, so treat it as a burst guard, not an exact count.

Deploy after changing either.

## Development

```sh
npm test            # the Worker against fake bindings, with the real SQL on SQLite
npm run typecheck
npm run check       # builds it and checks the template, without deploying
npm run check:local # the same with your real config, before a deploy
```

`test/fixtures/full-report.json` is written by the app's own tests, with every field set. If
the app's report changes, that file changes, and these tests fail until `src/validate.ts`
matches it. To rewrite it, run this from the repository root:

```sh
UPDATE_WORKER_FIXTURE=1 swift test --filter DeviceReportSenderTests
```
