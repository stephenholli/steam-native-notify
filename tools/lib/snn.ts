// Shared plumbing for the dev tools (tools/fire, tools/capture, tools/mep):
// the plugin's identity, where its runtime state and the installed .star live
// on each platform, how to read plugin.log, how to write the dev door, and
// the log-prefix contract from frontend/log.ts. backend/main.lua computes the
// same paths; a change there is a change here.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

/** millennium.toml [plugin] id; also the AppUserModelId Windows records toasts under. */
export const PLUGIN_ID = 'me.tysmith.steam-native-notifications';

export const IS_WINDOWS = process.platform === 'win32';

// The frontend's verdict on its notification hook, written once per real
// start, so the newest one dates the running frontend.
const HOOK = /hook installed|hook failed|g_PopupManager never appeared/;

/**
 * The prefixes frontend/log.ts and backend/main.lua write, the ones the tools
 * read. Case-sensitive throughout: a renamed prefix must read as "nothing
 * logged", never as a stale answer.
 */
export const LOG = {
	hook: HOOK,
	// `helper: ` with its colon: the focus helper's own lines name
	// steamwebhelper and are not startup.
	startup: new RegExp(`${HOOK.source}|helper: |steam-url: registered`),
	notification: /from-toast |toast .* -> |dev-fire|replay: candidates|replay: invoke|click-bridge|steam-url: click|steam-url: ignored|focus:/,
} as const;

/** %LOCALAPPDATA%: the base of every per-user runtime path on Windows. */
export function localAppData(): string {
	return process.env.LOCALAPPDATA ?? join(process.env.USERPROFILE ?? homedir(), 'AppData', 'Local');
}

/**
 * Where every runtime file lives: the packed .star has no plugin directory,
 * so the backend materializes its helper here, mirrors its log here, and
 * reads the dev door here (backend/main.lua runtime_dir).
 */
export function runtimeDir(): string {
	if (IS_WINDOWS) return join(localAppData(), 'steam-native-notifications');
	if (process.platform === 'darwin') return join(homedir(), 'Library', 'Caches', 'steam-native-notifications');
	return join(process.env.XDG_CACHE_HOME ?? join(homedir(), '.cache'), 'steam-native-notifications');
}

export function pluginLogPath(): string {
	return join(runtimeDir(), 'plugin.log');
}

/**
 * Millennium's external protocol socket: /tmp on POSIX, the user's temp
 * directory on Windows (Millennium: src/include/mep/mep_server.h).
 */
export function mepSocketPath(): string {
	return IS_WINDOWS ? join(tmpdir(), 'millennium-mep.sock') : '/tmp/millennium-mep.sock';
}

/**
 * The Steam directory the backend published at its last load
 * (backend/main.lua publish_steam_dir): rewritten every load, removed when
 * Millennium had no answer. The authoritative path, and proof the backend
 * has loaded at least once. Null when absent or empty, never a throw.
 */
function publishedSteamDir(): string | null {
	let dir: string;
	try {
		dir = readFileSync(join(runtimeDir(), 'steam-dir'), 'utf8').trim().replace(/[/\\]+$/, '');
	} catch {
		// Absent, or removed by a backend load between one moment and the next.
		return null;
	}
	return dir !== '' && existsSync(dir) ? dir : null;
}

let steamDirCache: string | null | undefined;

/**
 * Where Steam is: the published path first, then the platform's own answer
 * (the registry on Windows, ~/.steam/steam elsewhere). Null rather than a
 * guess, so a tool never reports on a Steam that is not the one running.
 * Found once per run: the registry probe spawns a process per key.
 */
export function steamDir(): string | null {
	if (steamDirCache === undefined) steamDirCache = findSteamDir();
	return steamDirCache;
}

function findSteamDir(): string | null {
	const published = publishedSteamDir();
	if (published) return published;
	if (IS_WINDOWS) return registrySteamDir();
	const posix = join(homedir(), '.steam', 'steam');
	return existsSync(posix) ? posix : null;
}

function registrySteamDir(): string | null {
	const keys: Array<[string, string]> = [
		['HKCU\\Software\\Valve\\Steam', 'SteamPath'],
		['HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam', 'InstallPath'],
		['HKLM\\SOFTWARE\\Valve\\Steam', 'InstallPath'],
	];
	for (const [key, name] of keys) {
		const proc = Bun.spawnSync(['reg', 'query', key, '/v', name]);
		if (proc.exitCode !== 0) continue;
		const m = /REG_SZ\s+(.+?)\s*$/m.exec(proc.stdout.toString());
		if (!m) continue;
		const dir = m[1].replace(/\//g, '\\');
		if (existsSync(dir)) return dir;
	}
	return null;
}

/**
 * Where starlight's output_path = "auto" installs the .star: under the Steam
 * install on Windows (MILLENNIUM__PLUGINS_PATH = <install>/plugins), under
 * ~/.local/share/millennium on POSIX. Null when the Windows install cannot be
 * found.
 */
export function starPath(): string | null {
	if (IS_WINDOWS) {
		const steam = steamDir();
		return steam ? join(steam, 'millennium', 'plugins', `${PLUGIN_ID}.star`) : null;
	}
	return join(homedir(), '.local', 'share', 'millennium', 'plugins', `${PLUGIN_ID}.star`);
}

/**
 * Millennium's loader lines on Linux go to Steam's console log (the
 * "Delegating frontend load" stamp that dates the running frontend). Null
 * elsewhere: Windows has no such log (Millennium logs to its own console
 * there), and the macOS one is unverified.
 */
export function steamConsoleLogPath(): string | null {
	return process.platform === 'linux' ? join(homedir(), '.steam', 'steam', 'logs', 'console-linux.txt') : null;
}

/** Every non-empty line of plugin.log; an empty array when there is none. */
export function readPluginLog(): string[] {
	const path = pluginLogPath();
	if (!existsSync(path)) return [];
	return readFileSync(path, 'utf8').split(/\r?\n/).filter((l) => l !== '');
}

/** The `[YYYY-MM-DD HH:MM:SS]` stamp a log line opens with, or null. */
export function parseStamp(line: string): Date | null {
	const m = /^\[([0-9-]+ [0-9:]+)\]/.exec(line);
	return m ? new Date(m[1].replace(' ', 'T')) : null;
}

/**
 * One command into the dev door, written whole: one JSON line lands in a
 * sibling temp file first and is renamed into place, so the backend's
 * consume-once read never sees a partial command. UTF-8 without a BOM and
 * an LF newline: the backend hands the bytes to the frontend's JSON parse.
 */
export function writeDevFire(command: object): void {
	const dir = runtimeDir();
	mkdirSync(dir, { recursive: true });
	const target = join(dir, '.dev-fire');
	const tmp = `${target}.${process.pid}.tmp`;
	writeFileSync(tmp, `${JSON.stringify(command)}\n`, { encoding: 'utf8' });
	renameSync(tmp, target);
}

/**
 * The header comment of a tool is its usage text, the way tools/fire and
 * tools/mep have always printed their own: every leading comment line after
 * the shebang, with the comment marker stripped.
 */
export function usageFromHeader(file: string): string {
	const out: string[] = [];
	for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
		if (line.startsWith('#!')) continue;
		if (!line.startsWith('//')) break;
		out.push(line.replace(/^\/\/ ?/, ''));
	}
	return out.join('\n');
}

export function stamp(d: Date): string {
	const p = (n: number) => String(n).padStart(2, '0');
	return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
