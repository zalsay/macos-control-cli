/**
 * Install the narrow browser-side API path adapter before DSH's client boot.
 * Kept self-contained because DSH serializes this function into the page head.
 */
export function installCodexUiApiPrefixCompatibility() {
  const root = globalThis
  const marker = Symbol.for('safarier.dsh-codex-ui-api-compat.v1.1')
  if (root[marker] === true || typeof root.fetch !== 'function') return

  const originalFetch = root.fetch
  const apiRoot = '/api/michengai/dsh-codex-ui'
  const providerProxyPaths = new Set([
    '/dsh-provider-proxy/providers',
    '/dsh-provider-proxy/test',
    '/dsh-provider-proxy/reset-hits',
  ])
  const allowedMounts = new Set(['/dsh-mac/', '/dsh/', '/dsh-ubuntu/'])

  function rewrittenURL(input) {
    try {
      const page = root.location
      const base = new URL(root.document.baseURI)
      // The affected Codex UI and provider-proxy calls use root-absolute strings.
      // Do not inspect or reconstruct Request objects, URL objects, or other inputs.
      if (typeof input !== 'string' || !input.startsWith('/') || input.startsWith('//')) return undefined
      const target = new URL(input, page.href)
      if (target.origin !== page.origin || base.origin !== page.origin || base.search || base.hash) return undefined
      const isCodexUiApiPath = target.pathname === apiRoot || target.pathname.startsWith(`${apiRoot}/`)
      if (!isCodexUiApiPath && !providerProxyPaths.has(target.pathname)) return undefined

      // The standard root deployment is intentionally byte-for-byte untouched.
      if (base.pathname === '/') return undefined

      const mount = base.pathname.endsWith('/') ? base.pathname : `${base.pathname}/`
      if (!allowedMounts.has(mount)) return undefined
      if (page.pathname !== mount.slice(0, -1) && !page.pathname.startsWith(mount)) return undefined

      target.pathname = `${mount}${target.pathname.slice(1)}`
      return target.href
    } catch {
      // Compatibility must never turn a request the browser could make into an error.
      return undefined
    }
  }

  root.fetch = function safarierCodexUiCompatFetch(input) {
    const args = arguments
    const url = rewrittenURL(input)
    if (url !== undefined) {
      const rewrittenArgs = Array.from(args)
      rewrittenArgs[0] = url
      return Reflect.apply(originalFetch, this, rewrittenArgs)
    }
    return Reflect.apply(originalFetch, this, args)
  }

  Object.defineProperty(root, marker, { value: true })
}

/** A classic script suitable for DSH's parser-ordered head injection row. */
export function browserBootstrapScript() {
  return `;(${installCodexUiApiPrefixCompatibility.toString()})();`
}
