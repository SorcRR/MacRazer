// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// Receives a device test report from the app's Send button and emails it to the maintainer.
// Nothing is stored: the report goes into one email and is gone. See README.md for setup.
//
// Only the default export lives here: the runtime takes any named export of this module for
// an entry point (test/worker.test.ts checks).

import { handle, reply, type Env } from "./handler";
import { cleanUp } from "./limits";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handle(request, env, new Date());
    } catch (error) {
      console.error("unhandled", String(error));
      return reply(503, "unavailable");
    }
  },

  async scheduled(_controller: unknown, env: Env): Promise<void> {
    await cleanUp(env.DB, new Date());
  },
};
