import { test as base, expect } from "@playwright/test";
export { expect };
export type { Page, APIRequestContext } from "@playwright/test";
export const test = base.extend<{ controlAudit: void }>({
  controlAudit: [
    async ({ page }, use, testInfo) => {
      const controls: object[] = [];
      const errors: string[] = [];
      await page.exposeFunction("auditControl", (entry: object) =>
        controls.push(entry),
      );
      await page.addInitScript(() => {
        for (const eventName of ["click", "change"])
          document.addEventListener(
            eventName,
            (event) => {
              const element = (event.target as Element)?.closest(
                '[role="button"],[role="tab"],[role="radio"],[role="switch"],button,input,textarea',
              );
              if (!element) return;
              const label =
                element.getAttribute("aria-label") ||
                element.textContent?.trim() ||
                element.getAttribute("placeholder") ||
                element.tagName;
              // Never record entered values, credentials, tokens, or URL query parameters.
              (window as any).auditControl({
                event: eventName,
                page: location.pathname,
                label: label.slice(0, 160),
                role: element.getAttribute("role") || element.tagName,
              });
            },
            true,
          );
      });
      page.on("pageerror", (error) => errors.push(error.message));
      await use();
      await testInfo.attach("controls", {
        body: JSON.stringify({ controls, errors }),
        contentType: "application/json",
      });
      expect(errors, "No unhandled browser application errors").toEqual([]);
    },
    { auto: true },
  ],
});
