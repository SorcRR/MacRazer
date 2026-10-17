# MacRazer reports Worker

The device test's **Send** button posts its report here. This Cloudflare Worker checks the
report, emails it to the maintainer, and keeps nothing. The only stored data is a count of
reports per day, used for the caps below.

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
| 429 | Too many: 3 a minute or 10 a day from one IP, or 200 a day in total | Try again tomorrow |
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

## Setup

You need a Cloudflare account with a domain on it. Sending to your own verified address is
free on every plan.

Your addresses never go in the repository. [wrangler.toml](wrangler.toml) is a public
template with placeholders. Your three private values live in a settings file outside the
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

4. Create `~/.config/macrazer-reports/settings.env` with your three values:

   ```sh
   DESTINATION=you@yourdomain.com
   SENDER=macrazer-reports@yourdomain.com
   DATABASE_ID=the-id-from-step-3
   ```

   - `DESTINATION`: the address you verified in step 2. It goes in both `destination_address`,
     which locks the binding to it, and `DESTINATION_ADDRESS`, which the Worker sends to.
   - `SENDER`: any address on the Email Routing domain. It doesn't need a mailbox.
   - To keep the file somewhere else, set `MACRAZER_REPORTS_SETTINGS` to its path.

5. Create the table, then deploy:

   ```sh
   npm run migrate
   npm run deploy
   ```

   On an account's first Worker, Wrangler asks you to pick a `workers.dev` subdomain. It then
   prints the Worker's address, like `https://macrazer-reports.<subdomain>.workers.dev`.
   `ProjectLinks.deviceReports` in `Sources/MacRazer/AppInfo.swift` must point at it, with
   `/v1/device-report` on the end.

   Always deploy with `npm run deploy`. A plain `npx wrangler deploy` reads the template, with
   its placeholder addresses.

6. Set the salt for the IP hashes, a random secret you never need to see:

   ```sh
   npm run salt
   ```

   Until it's set, the Worker answers every report with a 503 and sends nothing.

7. Send a test report. A 200 here should arrive as an email, maybe in spam the first time:

   ```sh
   curl -i https://macrazer-reports.<subdomain>.workers.dev/v1/device-report \
     -H 'content-type: application/json' --data @test/fixtures/full-report.json
   ```

   A 503 means a step above is missing. `npm run tail` shows why, for example
   `E_SENDER_NOT_VERIFIED` when the sender's domain doesn't have Email Routing.

## Changing where reports go

Verify the new address in Email Routing first. Then change `DESTINATION` in your settings file
and run `npm run deploy`. The binding can't send anywhere but that address, whatever a request
says. The Worker never takes an address from the request.

## Changing the caps

- Per day: `DAILY_PER_IP` and `DAILY_TOTAL` in `wrangler.toml`. They aren't private, so they
  live in the template.
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
