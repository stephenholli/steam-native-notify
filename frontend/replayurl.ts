/**
 * `steam://snn/replay/<toast-name>` -> the toast name, or null for anything
 * else. Steam passes the URL through verbatim, so this end validates it: the
 * only shape ever emitted is one replay token of the characters Steam's own
 * popup names use.
 *
 * Its own module, free of Millennium imports, so tools/test-frontend can load
 * and call it; steamurl.ts re-exports it for the client.
 */
export function replayNameFromSteamUrl(url: string): string | null {
	const match = /^steam:\/{1,2}snn\/replay\/([A-Za-z0-9_.-]+)\/?$/.exec(url.trim());
	return match ? match[1] : null;
}
