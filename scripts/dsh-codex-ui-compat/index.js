import { browserBootstrapScript } from './browser-bootstrap.js'

export const name = 'safarier-dsh-codex-ui-compat'
export const inject = ['webServer']

/** Register an early, page-scoped compatibility shim using DSH's native index tap. */
export function apply(ctx) {
  const script = browserBootstrapScript()
  ctx.effect(() => ctx.webServer.tapIndex((html) =>
    // The frontend-static shell adds <base href="./"> after taps; inserting at
    // the head start therefore leaves the base first and this shim before all
    // structured DSH boot rows and application module scripts.
    html.replace(/<head(?:\s[^>]*)?>/i, (opening) => `${opening}<script>${script}</script>`),
  ))
}
