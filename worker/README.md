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

1. Install the tools and log in:

   ```sh
   cd worker
   npm install
   npx wrangler login
   ```

2. In the Cloudflare dashboard, enable **Email Routing** on your domain. Under destination
   addresses, add the address reports should go to, then click the link in the verification
   email.

3. In [wrangler.toml](wrangler.toml), set:
   - `destination_address` and `DESTINATION_ADDRESS`: the address you just verified, in both
     places. The first locks the binding to it, the second is what the Worker sends to, and
     `npm test` fails if they differ.
   - `SENDER_ADDRESS`: any address on the Email Routing domain, such as
     `macrazer-reports@yourdomain.com`. It doesn't need a mailbox.

4. Create the database, put its id in `wrangler.toml` as `database_id`, and create the table:

   ```sh
   npx wrangler d1 create macrazer-reports
   npx wrangler d1 migrations apply macrazer-reports --remote
   ```

5. Set the salt for the IP hashes. Any long random string works; you never need it again.

   ```sh
   openssl rand -hex 32 | npx wrangler secret put IP_SALT
   ```

6. Deploy:

   ```sh
   npm run deploy
   ```

   Wrangler prints the Worker's address, like `https://macrazer-reports.<subdomain>.workers.dev`.
   `ProjectLinks.deviceReports` in `Sources/MacRazer/AppInfo.swift` must point at it, with
   `/v1/device-report` on the end.

7. Send a test report. A 200 here should arrive as an email:

   ```sh
   curl -i https://macrazer-reports.<subdomain>.workers.dev/v1/device-report \
     -H 'content-type: application/json' --data @test/fixtures/full-report.json
   ```

   A 503 means a step above is missing. `npx wrangler tail` shows why, for example
   `E_SENDER_NOT_VERIFIED` when the sender's domain doesn't have Email Routing.

## Changing where reports go

Verify the new address in Email Routing first. Then change `destination_address` and
`DESTINATION_ADDRESS` in `wrangler.toml`, run `npm test` to check they match, and run
`npm run deploy`. The binding can't send anywhere but `destination_address`, whatever a request
says. The Worker never takes an address from the request.

## Changing the caps

- Per day: `DAILY_PER_IP` and `DAILY_TOTAL` in `wrangler.toml`.
- Per minute: `limit` under `[[ratelimits]]`. Cloudflare only allows a `period` of 10 or 60
  seconds, and counts per location, so treat it as a burst guard, not an exact count.

Deploy after changing either.

## Development

```sh
npm test            # the Worker against fake bindings, with the real SQL on SQLite
npm run typecheck
npm run check       # builds it and checks wrangler.toml, without deploying
```

`test/fixtures/full-report.json` is written by the app's own tests, with every field set. If
the app's report changes, that file changes, and these tests fail until `src/validate.ts`
matches it. To rewrite it, run this from the repository root:

```sh
UPDATE_WORKER_FIXTURE=1 swift test --filter DeviceReportSenderTests
```
