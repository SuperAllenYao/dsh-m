/**
 * client.js — DSH desktop client plugin for dsh-m-link (M1).
 *
 * Self-contained browser bundle (no build step): the DSH client module system
 * loads this file through /plugins/dsh-m-link/client.js and calls the exported
 * Cordis client plugin ({inject, apply}). It registers one Settings section,
 * "DSH-m 手机连接", that talks to the host plugin over an exact Fetch route on
 * the official web server (same-origin browser cookie auth, owner peer only):
 *
 * POST /api/dsh-m-link/admin {"action": "..."}
 *
 * The UI is deliberately built from plain React elements with inline styles so
 * the bundle needs only the platform "react" module and stays inside the DSH
 * settings design language (system font, compact rows, quiet borders). The
 * pairing QR PNG is rendered by the host (macOS CoreImage) and arrives as a
 * data URL — the one-time pair token never appears in this file, in logs, or on
 * disk unless the debug switch is on.
 */
window.__ModuleLoader__.load({
	id: "dsh-m-link",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		const React = require("react");
		const h = React.createElement;

		const ADMIN_PATH = "/api/dsh-m-link/admin";
		const DEPLOY_PATH = "/api/dsh-m-link/deploy";
		const POLL_MS = 5000;
		const DEPLOY_POLL_MS = 700;

		const styles = {
			panel: { display: "flex", flexDirection: "column", gap: "14px", fontSize: "13px", lineHeight: "1.5" },
			card: {
				border: "1px solid color-mix(in srgb, currentColor 14%, transparent)",
				borderRadius: "10px",
				padding: "12px",
				background: "color-mix(in srgb, currentColor 3%, transparent)",
			},
			h2: { fontSize: "14px", fontWeight: 600, margin: 0 },
			sub: { fontSize: "12px", opacity: 0.62, margin: "2px 0 0" },
			row: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "12px", padding: "7px 0" },
			rowBorder: { borderTop: "1px solid color-mix(in srgb, currentColor 8%, transparent)" },
			label: { opacity: 0.66, flex: "0 0 auto" },
			value: { textAlign: "right", wordBreak: "break-all", fontVariantNumeric: "tabular-nums" },
			mono: { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: "11.5px" },
			button: {
				font: "inherit",
				fontSize: "12px",
				padding: "5px 12px",
				borderRadius: "7px",
				cursor: "pointer",
				border: "1px solid color-mix(in srgb, currentColor 22%, transparent)",
				background: "color-mix(in srgb, currentColor 6%, transparent)",
				color: "inherit",
			},
			buttonPrimary: {
				font: "inherit",
				fontSize: "12px",
				padding: "5px 12px",
				borderRadius: "7px",
				cursor: "pointer",
				border: "1px solid color-mix(in srgb, currentColor 30%, transparent)",
				background: "color-mix(in srgb, currentColor 14%, transparent)",
				color: "inherit",
				fontWeight: 600,
			},
			buttonDanger: {
				font: "inherit",
				fontSize: "12px",
				padding: "4px 10px",
				borderRadius: "6px",
				cursor: "pointer",
				border: "1px solid color-mix(in srgb, #e5484d 55%, transparent)",
				background: "transparent",
				color: "color-mix(in srgb, #e5484d 86%, currentColor)",
			},
			buttonDisabled: { opacity: 0.45, cursor: "default" },
			badge: { display: "inline-block", fontSize: "11px", padding: "1px 7px", borderRadius: "999px", border: "1px solid color-mix(in srgb, currentColor 20%, transparent)" },
			dot: (color) => ({ display: "inline-block", width: "7px", height: "7px", borderRadius: "50%", background: color, marginRight: "6px", verticalAlign: "middle" }),
			banner: {
				border: "1px solid color-mix(in srgb, #e5484d 55%, transparent)",
				background: "color-mix(in srgb, #e5484d 10%, transparent)",
				borderRadius: "8px",
				padding: "10px 12px",
				fontSize: "12px",
			},
			grid: { display: "flex", gap: "14px", alignItems: "flex-start", flexWrap: "wrap" },
			qrBox: { flex: "0 0 210px", boxSizing: "border-box", display: "flex", flexDirection: "column", alignItems: "center", gap: "8px" },
			qrImg: { width: "186px", height: "186px", imageRendering: "pixelated", background: "#fff", borderRadius: "8px", padding: "6px", boxSizing: "border-box" },
			qrPlaceholder: {
				width: "186px",
				height: "186px",
				display: "flex",
				alignItems: "center",
				justifyContent: "center",
				textAlign: "center",
				padding: "16px",
				boxSizing: "border-box",
				border: "1px dashed color-mix(in srgb, currentColor 22%, transparent)",
				borderRadius: "8px",
				opacity: 0.7,
				fontSize: "12px",
			},
 // P3/D6: the inline QR stays compact, but is a real button so the dense
 // payload can be scanned from a full-screen, much larger rendering.
			qrButton: { padding: 0, margin: 0, border: "none", background: "none", cursor: "zoom-in", display: "block", lineHeight: 0, borderRadius: "8px" },
			qrOverlay: {
				position: "fixed",
				inset: 0,
				zIndex: 2147483000,
				background: "rgba(0, 0, 0, 0.74)",
				display: "flex",
				alignItems: "center",
				justifyContent: "center",
				padding: "24px",
				cursor: "zoom-out",
			},
			qrOverlayCard: {
				display: "flex",
				flexDirection: "column",
				alignItems: "center",
				gap: "12px",
				padding: "16px",
				borderRadius: "14px",
				background: "#fff",
				color: "#111",
				boxShadow: "0 24px 64px rgba(0, 0, 0, 0.45)",
				cursor: "default",
			},
			qrOverlayImg: {
				display: "block",
				background: "#fff",
 // Fullscreen enlarging for high-density payloads (D6): >= 320px, capped
 // at 420px so the quiet zone always fits on a laptop screen.
				width: "clamp(320px, 62vw, 420px)",
				height: "clamp(320px, 62vw, 420px)",
				imageRendering: "pixelated",
			},
			qrOverlayHint: { fontSize: "12px", color: "#333", opacity: 0.72, textAlign: "center" },
			grow: { flex: "1 1 280px", minWidth: "260px", display: "flex", flexDirection: "column", gap: "14px" },
			pairCodeRow: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "14px", flexWrap: "wrap" },
			pairCodeDigits: { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: "30px", fontWeight: 600, letterSpacing: "6px", fontVariantNumeric: "tabular-nums", lineHeight: 1.15, whiteSpace: "nowrap" },
			pairCodeExpired: { opacity: 0.4 },
			progressTrack: { height: "4px", borderRadius: "999px", background: "color-mix(in srgb, currentColor 12%, transparent)", overflow: "hidden", marginTop: "2px" },
			progressFill: (percent, color) => ({ height: "100%", width: Math.max(0, Math.min(100, percent)) + "%", background: color, transition: "width 0.9s linear" }),
			deviceRow: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "12px", padding: "9px 0" },
			deviceMeta: { display: "flex", flexDirection: "column", gap: "1px", minWidth: 0 },
			deviceName: { fontWeight: 600, fontSize: "12.5px", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
			auditList: { display: "flex", flexDirection: "column", gap: "3px", marginTop: "6px" },
			auditLine: { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: "11px", opacity: 0.66, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
			footer: { fontSize: "11.5px", opacity: 0.55 },
			input: {
				font: "inherit",
				fontSize: "12px",
				padding: "5px 8px",
				borderRadius: "7px",
				border: "1px solid color-mix(in srgb, currentColor 22%, transparent)",
				background: "color-mix(in srgb, currentColor 4%, transparent)",
				color: "inherit",
				minWidth: 0,
				flex: "1 1 160px",
			},
			formGrid: { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: "8px", marginTop: "6px" },
			fieldLabel: { fontSize: "11.5px", opacity: 0.6, marginBottom: "2px", display: "block" },
			stepList: { display: "flex", flexDirection: "column", gap: "4px", marginTop: "8px" },
			stepRow: { display: "flex", alignItems: "baseline", gap: "8px", fontSize: "12px", flexWrap: "wrap" },
			stepDotStyle: { width: "16px", display: "inline-block", textAlign: "center", opacity: 0.8 },
			deployLog: {
				marginTop: "8px",
				maxHeight: "220px",
				overflow: "auto",
				padding: "8px",
				borderRadius: "8px",
				border: "1px solid color-mix(in srgb, currentColor 10%, transparent)",
				background: "color-mix(in srgb, currentColor 2%, transparent)",
				fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
				fontSize: "11px",
				lineHeight: "1.45",
				whiteSpace: "pre-wrap",
				wordBreak: "break-all",
			},
			logLine: { opacity: 0.78 },
			logWarn: { opacity: 1, color: "color-mix(in srgb, #f5a623 80%, currentColor)" },
			logError: { opacity: 1, color: "color-mix(in srgb, #e5484d 88%, currentColor)" },
			promptBox: {
				marginTop: "8px",
				padding: "10px 12px",
				borderRadius: "8px",
				border: "1px solid color-mix(in srgb, #f5a623 55%, transparent)",
				background: "color-mix(in srgb, #f5a623 10%, transparent)",
				fontSize: "12px",
				display: "flex",
				flexDirection: "column",
				gap: "8px",
			},
			hintList: { fontSize: "11.5px", opacity: 0.7, marginTop: "6px", lineHeight: 1.5 },
			successBox: {
				marginTop: "8px",
				padding: "10px 12px",
				borderRadius: "8px",
				border: "1px solid color-mix(in srgb, #30a46c 45%, transparent)",
				background: "color-mix(in srgb, #30a46c 8%, transparent)",
				fontSize: "12px",
			},
			linkButton: { font: "inherit", fontSize: "12px", color: "inherit", background: "none", border: "none", padding: 0, cursor: "pointer", textDecoration: "underline", opacity: 0.7 },
		};

		async function admin(action, payload) {
			const response = await fetch(ADMIN_PATH, {
				method: "POST",
				credentials: "same-origin",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({ action, ...(payload === undefined ? {} : payload) }),
			});
			if (!response.ok) {
				let detail = "";
				try {
					const parsed = await response.json();
					detail = parsed?.error ?? parsed?.message ?? "";
				} catch {
 /* not JSON */
				}
				throw new Error("admin " + action + " failed (HTTP " + response.status + (detail ? ", " + detail : "") + ")");
			}
			const body = await response.json();
			if (body?.ok !== true) throw new Error(body?.error ?? "admin request rejected");
			return body.data;
		}

		async function deployAdmin(action, payload) {
			const response = await fetch(DEPLOY_PATH, {
				method: "POST",
				credentials: "same-origin",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({ action, ...(payload === undefined ? {} : payload) }),
			});
			let parsed;
			try {
				parsed = await response.json();
			} catch {
				parsed = undefined;
			}
			if (!response.ok || parsed?.ok !== true) {
				const detail = parsed?.message ?? parsed?.error ?? "";
				throw new Error(action + " failed (HTTP " + response.status + (detail ? ", " + detail : "") + ")");
			}
			return parsed.data;
		}

		function relativeTime(timestamp) {
			if (typeof timestamp !== "number" || Number.isFinite(timestamp) === false) return "—";
			const delta = Date.now() - timestamp;
			if (delta < 60_000) return "刚刚";
			if (delta < 3_600_000) return Math.floor(delta / 60_000) + " 分钟前";
			if (delta < 86_400_000) return Math.floor(delta / 3_600_000) + " 小时前";
			return Math.floor(delta / 86_400_000) + " 天前";
		}

		function formatFingerprint(value) {
			if (typeof value !== "string" || value.length === 0) return "—";
			return value;
		}

		function shortenFingerprint(value, head = 17, tail = 8) {
			if (typeof value !== "string") return "—";
			if (value.length <= head + tail + 1) return value;
			return value.slice(0, head) + "…" + value.slice(-tail);
		}

		function StatusDot(props) {
			const { ready, contract, started } = props;
			let color = "#8a8f98";
			if (ready === true) color = "#30a46c";
			else if (contract !== undefined && contract?.ok === false) color = "#e5484d";
			else if (started === false) color = "#f5a623";
			return h("span", { style: styles.dot(color) });
		}

		function Row(props) {
			const { label, children, first, mono } = props;
			return h(
				"div",
				{ style: first === true ? styles.row : { ...styles.row, ...styles.rowBorder } },
				h("span", { style: styles.label }, label),
				h("span", { style: mono === true ? { ...styles.value, ...styles.mono } : styles.value }, children),
			);
		}

		function Button(props) {
			const { children, onClick, variant, disabled, title } = props;
			const base = variant === "primary" ? styles.buttonPrimary : variant === "danger" ? styles.buttonDanger : styles.button;
			return h(
				"button",
				{
					type: "button",
					onClick,
					disabled,
					title,
					style: disabled ? { ...base, ...styles.buttonDisabled } : base,
				},
				children,
			);
		}

		function CopyValue(props) {
			const { value, text } = props;
			const [copied, setCopied] = React.useState(false);
			const copy = async () => {
				try {
					await navigator.clipboard.writeText(String(text ?? value));
					setCopied(true);
					setTimeout(() => setCopied(false), 1200);
				} catch {
 /* clipboard unavailable */
				}
			};
			return h(
				"button",
				{ type: "button", onClick: copy, style: { ...styles.linkButton, textAlign: "right", wordBreak: "break-all" }, title: "复制" },
				copied ? "已复制" : value,
			);
		}

		function DeployStepList(props) {
			const steps = Array.isArray(props.steps) ? props.steps : [];
			if (steps.length === 0) return null;
			return h(
				"div",
				{ style: styles.stepList, "data-dshm-deploy-steps": "" },
				steps.map((step) => {
					const color = step.status === "ok" ? "#30a46c" : step.status === "failed" ? "#e5484d" : step.status === "running" ? "#f5a623" : "currentColor";
					const symbol = step.status === "ok" ? "✓" : step.status === "failed" ? "✕" : step.status === "running" ? "…" : "○";
					return h(
						"div",
						{ key: step.id, style: styles.stepRow },
						h("span", { style: { ...styles.stepDotStyle, color } }, symbol),
						h("span", { style: { fontWeight: step.status === "running" ? 600 : 400 } }, step.title),
						step.detail === undefined ? null : h("span", { style: styles.sub }, step.detail),
					);
				}),
			);
		}

		function DeployLog(props) {
			const lines = Array.isArray(props.lines) ? props.lines : [];
			const boxRef = React.useRef(undefined);
			React.useEffect(() => {
				if (boxRef.current !== undefined && boxRef.current !== null) boxRef.current.scrollTop = boxRef.current.scrollHeight;
			}, [lines]);
			return h(
				"div",
				{ ref: boxRef, style: styles.deployLog, "data-dshm-deploy-log": "" },
				lines.length === 0
					? h("div", { style: styles.sub }, "等待部署日志…")
					: lines.map((line) => h("div", { key: String(line.seq), style: line.level === "error" ? styles.logError : line.level === "warn" ? styles.logWarn : styles.logLine }, line.text)),
			);
		}

		function RemoteRelayCard() {
			const [env, setEnv] = React.useState(undefined);
			const [host, setHost] = React.useState("");
			const [sshPort, setSshPort] = React.useState("22");
			const [user, setUser] = React.useState("root");
			const [authMode, setAuthMode] = React.useState("key");
			const [keyName, setKeyName] = React.useState("");
			const [keyText, setKeyText] = React.useState("");
			const [password, setPassword] = React.useState("");
			const [advancedOpen, setAdvancedOpen] = React.useState(false);
			const [controlPort, setControlPort] = React.useState("");
			const [bridgeRange, setBridgeRange] = React.useState("");
			const [installDir, setInstallDir] = React.useState("/usr/local/bin");
			const [forceReinstall, setForceReinstall] = React.useState(false);
			const [deployId, setDeployId] = React.useState(undefined);
			const [status, setStatus] = React.useState(undefined);
			const [logs, setLogs] = React.useState([]);
			const [error, setError] = React.useState(undefined);
			const [qr, setQr] = React.useState(undefined);
			const [busy, setBusy] = React.useState(false);
			const [activation, setActivation] = React.useState(undefined);
			const [activating, setActivating] = React.useState(false);
			const cursorRef = React.useRef(0);

			const loadEnv = React.useCallback(async () => {
				try {
					const data = await deployAdmin("env");
					setEnv(data);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				}
			}, []);

			React.useEffect(() => {
				loadEnv();
			}, [loadEnv]);

 // Stream the deploy progress while one is active.
			React.useEffect(() => {
				if (deployId === undefined) return undefined;
				let cancelled = false;
				let timer;
				const tick = async () => {
					try {
						const data = await deployAdmin("status", { deployId, since: cursorRef.current });
						if (cancelled) return;
						setStatus(data);
						if (Array.isArray(data.logs) && data.logs.length > 0) {
							if (typeof data.cursor === "number") cursorRef.current = data.cursor;
							setLogs((current) => current.concat(data.logs));
						}
						if (data.active !== true) {
							setBusy(false);
 // Stop polling once the deploy finished; a new deploy sets a new deployId.
							if (timer !== undefined) clearInterval(timer);
						}
						if (data.error !== undefined) setError(String(data.error.message ?? data.error.code ?? "部署失败") + (data.error.hint ? " — " + data.error.hint : ""));
					} catch (caught) {
						if (!cancelled) {
							setBusy(false);
							setError(String(caught?.message ?? caught));
						}
					}
				};
				tick();
				timer = setInterval(tick, DEPLOY_POLL_MS);
				return () => {
					cancelled = true;
					clearInterval(timer);
				};
			}, [deployId]);

 // Render the App "服务器配置" QR once the deploy produced one.
			React.useEffect(() => {
				if (status?.state !== "done" || status?.result?.appConfig === undefined || qr !== undefined) return;
				setQr("loading");
				deployAdmin("qr", { text: status.result.appConfig })
					.then((data) => setQr(data.dataUrl))
					.catch(() => setQr("unavailable"));
			}, [status, qr]);

			const pickKeyFile = async (event) => {
				const file = event?.target?.files?.[0];
				if (file === undefined) return;
				try {
					const text = await file.text();
					setKeyText(text);
					setKeyName(file.name);
					setError(undefined);
				} catch (caught) {
					setError("读取私钥文件失败：" + String(caught?.message ?? caught));
				}
			};

			const startDeploy = async () => {
				setError(undefined);
				setLogs([]);
				setStatus(undefined);
				setQr(undefined);
				setActivation(undefined);
				cursorRef.current = 0;
				if (host.trim().length === 0) {
					setError("请填写服务器地址（IP 或域名）");
					return;
				}
				if (authMode === "key" && keyText.length === 0) {
					setError("请选择 SSH 私钥文件");
					return;
				}
				if (authMode === "password" && password.length === 0) {
					setError("请输入 SSH 密码");
					return;
				}
				setBusy(true);
				try {
					const input = {
						host: host.trim(),
						sshPort: Number(sshPort) || 22,
						user: user.trim() || "root",
						auth: authMode,
						...(authMode === "key" ? { privateKey: keyText } : { password }),
						...(controlPort.trim() === "" ? {} : { controlPort: Number(controlPort) }),
						...(bridgeRange.trim() === "" ? {} : { bridgeRange: bridgeRange.trim() }),
						installDir: installDir.trim() || "/usr/local/bin",
						forceReinstall,
					};
					const data = await deployAdmin("start", { input });
 // Secrets must not linger in UI state once the host accepted them.
					setPassword("");
					setKeyText("");
					setKeyName("");
					setDeployId(data.deployId);
				} catch (caught) {
					setBusy(false);
					setError(String(caught?.message ?? caught));
				}
			};

			const confirmFingerprint = async () => {
				try {
					await deployAdmin("confirm", { deployId: status?.deployId ?? deployId, fingerprint: status?.prompt?.fingerprint });
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				}
			};

			const cancelDeploy = async () => {
				try {
					await deployAdmin("cancel", { deployId: status?.deployId ?? deployId });
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				}
			};

 // M2b-1: activate the tunnel in-process after deploy (no plugin reload).
			const activateTunnelNow = async () => {
				setActivating(true);
				setError(undefined);
				try {
					const data = await deployAdmin("tunnel.activate", {});
					setActivation(data);
					await loadEnv();
				} catch (caught) {
					const message = String(caught?.message ?? caught);
					setActivation({ ok: false, error: message });
					setError("运行时激活失败：" + message + "（可重试；仍失败请重启 DSH）");
				} finally {
					setActivating(false);
				}
			};

			const currentTunnel = env?.tunnel;
			const active = status?.active === true;
			const done = status?.state === "done";
			const result = status?.result;
			const sshMissing = env !== undefined && env.sshAvailable !== true;
			const assetsMissing = env !== undefined && Array.isArray(env.assets?.targets) && env.assets.targets.length === 0;

			return h(
				"div",
				{ style: styles.card, "data-dshm-remote-relay-card": "" },
				h(
					"div",
					{ style: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "12px" } },
					h("span", { style: { fontWeight: 600 } }, "远程中转（自建服务器）"),
					h(
						"span",
						{ style: styles.sub },
						currentTunnel?.configured === true
							? "已部署 · " + String(currentTunnel.controlOrigin ?? "") + (env?.runtimeTunnel?.state ? " · 运行时隧道 " + String(env.runtimeTunnel.state) : "")
							: "未部署（可选：让手机在蜂窝网络下经自建服务器连接）",
					),
				),
				sshMissing ? h("div", { style: styles.banner }, "本机缺少 ssh / scp / ssh-keyscan，无法部署。macOS 自带 OpenSSH，请检查 PATH。") : null,
				assetsMissing ? h("div", { style: styles.banner }, "插件内没有可用的 relay 二进制：请在仓库执行 bash packages/dsh-m-relay/scripts/build-release.sh 后重新部署插件。") : null,
				error !== undefined ? h("div", { style: styles.banner }, "部署错误：" + error) : null,
				currentTunnel?.configured === true && status === undefined
					? h(
							"div",
							{ style: styles.hintList },
							"当前服务器：" + String(currentTunnel.controlOrigin ?? "—") + " · pin " + String(currentTunnel.pin ?? "").slice(0, 16) + "…",
							currentTunnel.deployedAt ? "（部署于 " + relativeTime(Date.parse(currentTunnel.deployedAt)) + "）" : "",
							" · 重新部署会做幂等升级（保留证书 / secret / state）。",
						)
					: null,
				h(
					"div",
					null,
					h("span", { style: styles.fieldLabel }, "服务器地址（IP 或域名）"),
					h(
						"div",
						{ style: { display: "flex", gap: "8px", flexWrap: "wrap" } },
						h("input", { style: styles.input, value: host, placeholder: "例如 relay.example.com", disabled: busy || active, onChange: (event) => setHost(event.target.value) }),
						h("input", { style: { ...styles.input, flex: "0 0 88px" }, value: sshPort, placeholder: "22", disabled: busy || active, onChange: (event) => setSshPort(event.target.value) }),
						h("input", { style: { ...styles.input, flex: "0 0 110px" }, value: user, placeholder: "root", disabled: busy || active, onChange: (event) => setUser(event.target.value) }),
					),
				),
				h(
					"div",
					null,
					h("span", { style: styles.fieldLabel }, "认证方式"),
					h(
						"div",
						{ style: { display: "flex", gap: "8px", flexWrap: "wrap", alignItems: "center" } },
						h(
							"select",
							{ style: { ...styles.input, flex: "0 0 130px" }, value: authMode, disabled: busy || active, onChange: (event) => setAuthMode(event.target.value) },
							h("option", { value: "key" }, "SSH 私钥文件"),
							h("option", { value: "password" }, "SSH 密码"),
						),
						authMode === "key"
							? h(
									"label",
									{ style: { ...styles.button, display: "inline-flex", alignItems: "center", gap: "6px" } },
									keyName.length > 0 ? "已选择：" + keyName : "选择私钥文件",
									h("input", { type: "file", style: { display: "none" }, disabled: busy || active, onChange: pickKeyFile }),
								)
							: h("input", { style: styles.input, type: "password", value: password, placeholder: "SSH 密码（仅内存，不落盘）", disabled: busy || active, onChange: (event) => setPassword(event.target.value) }),
					),
				),
				h(
					"details",
					{ style: { marginTop: "8px" }, open: advancedOpen, onToggle: (event) => setAdvancedOpen(event.target.open) },
					h("summary", { style: { ...styles.sub, cursor: "pointer" } }, "高级选项（控制端口 / bridge 端口段 / 安装目录 / 强制重装）"),
					h(
						"div",
						{ style: styles.formGrid },
						h(
							"label",
							null,
							h("span", { style: styles.fieldLabel }, "控制端口（留空自动选择，优先 443）"),
							h("input", { style: styles.input, value: controlPort, placeholder: "自动", disabled: busy || active, onChange: (event) => setControlPort(event.target.value) }),
						),
						h(
							"label",
							null,
							h("span", { style: styles.fieldLabel }, "bridge 端口段"),
							h("input", { style: styles.input, value: bridgeRange, placeholder: "自动（30000-30009）", disabled: busy || active, onChange: (event) => setBridgeRange(event.target.value) }),
						),
						h(
							"label",
							null,
							h("span", { style: styles.fieldLabel }, "安装目录"),
							h("input", { style: styles.input, value: installDir, placeholder: "/usr/local/bin", disabled: busy || active, onChange: (event) => setInstallDir(event.target.value) }),
						),
						h(
							"label",
							{ style: { display: "flex", alignItems: "center", gap: "6px", fontSize: "12px", opacity: 0.75 } },
							h("input", { type: "checkbox", checked: forceReinstall, disabled: busy || active, onChange: (event) => setForceReinstall(event.target.checked) }),
							"强制重装（会重启 relay；重复部署默认只升级）",
						),
					),
				),
				h(
					"div",
					{ style: { display: "flex", gap: "8px", marginTop: "10px", flexWrap: "wrap" } },
					h(Button, { variant: "primary", onClick: startDeploy, disabled: busy || active }, busy || active ? "部署中…" : done || currentTunnel?.configured === true ? "重新部署 / 升级" : "开始部署"),
					active ? h(Button, { onClick: cancelDeploy }, "取消") : null,
					env?.busy === true ? h("span", { style: styles.sub }, "（另一个部署正在进行）") : null,
				),
				h(DeployStepList, { steps: status?.steps }),
				status?.prompt?.kind === "host-fingerprint"
					? h(
							"div",
							{ style: styles.promptBox, "data-dshm-deploy-fingerprint": String(status.prompt.fingerprint ?? "") },
							h("div", { style: { fontWeight: 600 } }, status.prompt.mismatch === true ? "⚠️ 服务器主机指纹与上次记录不一致" : "首次连接：请核对服务器主机指纹"),
							h("div", { style: styles.mono }, String(status.prompt.keyType ?? "") + " " + String(status.prompt.fingerprint ?? "")),
							h("div", { style: styles.sub }, "请与该服务器管理终端上 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 的输出核对；不一致请立即取消（可能存在中间人）。"),
							h(
								"div",
								{ style: { display: "flex", gap: "8px" } },
								h(Button, { variant: "primary", onClick: confirmFingerprint }, "指纹一致，继续部署"),
								h(Button, { onClick: cancelDeploy }, "取消"),
							),
						)
					: null,
				logs.length > 0 || active ? h(DeployLog, { lines: logs }) : null,
				done && result !== undefined
					? h(
							"div",
							{ style: styles.successBox, "data-dshm-deploy-result": String(result.mode ?? "") },
							h("div", { style: { fontWeight: 600 } }, result.mode === "upgrade" ? "✅ 幂等升级完成" : "✅ 全新部署完成"),
							h("div", { style: { ...styles.mono, marginTop: "4px" } }, "控制地址：" + String(result.controlOrigin ?? "")),
							h("div", { style: styles.mono }, "证书 pin：" + String(result.pin ?? "")),
							h(
								"div",
								{ style: { ...styles.mono, marginTop: "4px", display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" } },
								"App 服务器配置：",
								h(CopyValue, { value: String(result.appConfig ?? "—"), text: result.appConfig }),
								qr === "loading" ? h("span", { style: styles.sub }, "二维码生成中…") : qr === "unavailable" ? h("span", { style: styles.sub }, "（本机二维码渲染不可用，可复制字符串）") : null,
							),
							qr !== undefined && qr !== "loading" && qr !== "unavailable" ? h("img", { src: qr, alt: "App 服务器配置二维码", style: { ...styles.qrImg, width: "150px", height: "150px", marginTop: "8px" } }) : null,
							h("div", { style: styles.hintList }, "本机 tunnel 配置已写入：" + String(result.tunnelStateFile ?? "—") + "（secret 文件 0600：" + String(result.secretFile ?? "—") + "）"),
							(() => {
								const view = activation ?? result.tunnelActivation;
								if (view?.ok === true) {
									return h(
										"div",
										{ style: { ...styles.hintList, color: "color-mix(in srgb, #30a46c 85%, currentColor)" } },
										"✅ 运行时隧道已激活" + (view.origin ? "：" + String(view.origin) : "") + (view.port ? "（bridge 端口 " + String(view.port) + "）" : "") + (view.unchanged === true ? "（配置未变化，未重连）" : "") + " — 无需重载插件，可直接扫码配对。",
									);
								}
								if (env?.canActivate === true) {
									return h(
										"div",
										{ style: styles.promptBox },
										h("div", { style: { fontWeight: 600 } }, "⚠️ 运行时隧道尚未激活"),
										view?.error ? h("div", { style: styles.sub }, String(view.error)) : h("div", { style: styles.sub }, "点击「激活连接」让新 relay 立即生效（免重载插件）。"),
										view?.rolledBack === true ? h("div", { style: styles.sub }, "已回退到旧隧道配置；本机 phone 链路未受影响。") : null,
										h("div", { style: { display: "flex", gap: "8px" } }, h(Button, { variant: "primary", onClick: activateTunnelNow, disabled: activating }, activating ? "激活中…" : view === undefined ? "激活连接" : "重试激活")),
									);
								}
								return h("div", { style: styles.hintList }, "当前运行模式无运行时激活接口：重载插件或重启 DSH 后公网隧道生效；重载前 LAN 配对不受影响。");
							})(),
							h(
								"details",
								{ style: { marginTop: "6px" } },
								h("summary", { style: { ...styles.sub, cursor: "pointer" } }, "查看 cordis.patch.yml 手动片段"),
								h("pre", { style: { ...styles.mono, whiteSpace: "pre-wrap", margin: "6px 0 0" } }, String(result.profileSnippet ?? "")),
							),
							result.nonDestructive !== null && result.nonDestructive !== undefined && result.nonDestructive.ok !== true ? h("div", { style: styles.hintList }, "⚠️ 非破坏性对比发现差异：" + JSON.stringify(result.nonDestructive)) : null,
						)
					: null,
				h(
					"div",
					{ style: { ...styles.sub, marginTop: "8px" } },
					"部署只新增 dshm-relay 自己的文件/用户/unit，不修改、不重启服务器上的其它服务；云安全组需手工放行控制端口与 bridge 端口段（引擎不自动改云防火墙）。",
				),
			);
		}

		function DshmPanel() {
			const [status, setStatus] = React.useState(undefined);
			const [pairing, setPairing] = React.useState(undefined);
			const [devices, setDevices] = React.useState([]);
			const [audit, setAudit] = React.useState([]);
			const [error, setError] = React.useState(undefined);
			const [busy, setBusy] = React.useState(false);
			const [now, setNow] = React.useState(Date.now());
			const [showAudit, setShowAudit] = React.useState(false);
			const [confirmRevoke, setConfirmRevoke] = React.useState(undefined);
 // P3/D6: fullscreen enlarged QR (the 186px inline code is too dense for
 // some phone cameras to resolve — see D6).
			const [qrZoom, setQrZoom] = React.useState(false);
			const lastAutoRefresh = React.useRef(0);
 // M5: a revoked phone is a terminal record — kept in devices.json and the
 // audit log (and blocked by auth/revoked), but not rendered in the settings
 // list, so revoked history cannot crowd the active devices.
			const activeDevices = devices.filter((device) => device.revoked !== true);

			const refreshStatus = React.useCallback(async (options) => {
				const quiet = options?.quiet === true;
				if (!quiet) setBusy(true);
				try {
					const [nextStatus, nextDevices] = await Promise.all([admin("status"), admin("devices.list")]);
					setStatus(nextStatus);
					setDevices(nextDevices.devices ?? []);
					setError(undefined);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					if (!quiet) setBusy(false);
				}
			}, []);

 // P3: the host re-renders the QR on every poll; if the signed payloadText did
 // not change, keep the previous image (identical data URL) so swapping the
 // <img> src for the same content never flashes the panel.
			const applyPairing = React.useCallback((next) => {
				setPairing((current) => {
					if (
						current !== undefined &&
						typeof current.payloadText === "string" &&
						current.payloadText === next?.payloadText &&
						current.qr?.ok === true &&
						next?.qr?.ok === true
					) {
						return { ...next, qr: current.qr };
					}
					return next;
				});
				setNow(Date.now());
			}, []);

			const loadPairing = React.useCallback(async () => {
				try {
					const nextPairing = await admin("pairing");
					applyPairing(nextPairing);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				}
			}, [applyPairing]);

 // M2a 8-digit pairing code derived state (countdown ticks via `now`).
			const pairCode = pairing?.code;
			const codeValue = typeof pairCode?.value === "string" && pairCode.value.length === 8 ? pairCode.value : "";
			const codeGrouped = codeValue.length === 8 ? codeValue.slice(0, 4) + " " + codeValue.slice(4) : "— — — —";
			const codeExpiresAt = typeof pairCode?.expiresAt === "number" ? pairCode.expiresAt : undefined;
			const codeRemainingMs = codeExpiresAt === undefined ? 0 : Math.max(0, codeExpiresAt - now);
			const codeTtlMs = typeof pairCode?.ttlMs === "number" && pairCode.ttlMs > 0 ? pairCode.ttlMs : 120000;
			const codeExpired = codeExpiresAt !== undefined && codeRemainingMs <= 0;
			const codePercent = (codeRemainingMs / codeTtlMs) * 100;

 // The host rotates the code itself, but this panel only reloads the
 // pairing payload on demand; when the countdown hits zero ask once for
 // the fresh code so the number shown is always live.
			React.useEffect(() => {
				if (!codeExpired) return undefined;
				if (lastAutoRefresh.current === codeExpiresAt) return undefined;
				lastAutoRefresh.current = codeExpiresAt;
				loadPairing();
				return undefined;
			}, [codeExpired, codeExpiresAt, loadPairing]);

 // P3/D5: refresh the signed pairing payload on the same 5s tick as the status.
 // The host re-signs an expired session inside payload() (P2), so the QR shown
 // while this panel stays open is always a live one-time token.
			React.useEffect(() => {
				refreshStatus();
				loadPairing();
				const timer = setInterval(() => {
					refreshStatus({ quiet: true });
					loadPairing();
				}, POLL_MS);
				const clock = setInterval(() => setNow(Date.now()), 1000);
				return () => {
					clearInterval(timer);
					clearInterval(clock);
				};
			}, [refreshStatus, loadPairing]);

			React.useEffect(() => {
				if (!qrZoom) return undefined;
				const onKeyDown = (event) => {
					if (event.key === "Escape") setQrZoom(false);
				};
				window.addEventListener("keydown", onKeyDown);
				return () => window.removeEventListener("keydown", onKeyDown);
			}, [qrZoom]);

			React.useEffect(() => {
				if (!showAudit) return undefined;
				let cancelled = false;
				const load = () => {
					admin("audit.tail", { limit: 12 })
						.then((data) => {
							if (!cancelled) setAudit(data.lines ?? []);
						})
						.catch(() => {});
				};
				load();
				const timer = setInterval(load, POLL_MS);
				return () => {
					cancelled = true;
					clearInterval(timer);
				};
			}, [showAudit]);

			const refreshPairing = async () => {
				setBusy(true);
				try {
					const next = await admin("pairing.refresh");
					applyPairing(next);
					setError(undefined);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					setBusy(false);
				}
			};

			const refreshCode = async () => {
				setBusy(true);
				try {
					const next = await admin("pairing.code.refresh");
					setPairing((current) => ({ ...(current ?? {}), code: next.code }));
					setNow(Date.now());
					setError(undefined);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					setBusy(false);
				}
			};

			const revoke = async (deviceId) => {
				setBusy(true);
				try {
					await admin("devices.revoke", { deviceId });
					setConfirmRevoke(undefined);
					await refreshStatus();
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					setBusy(false);
				}
			};

			const rotateLeaf = async () => {
				if (!window.confirm("用同一 CA 重签叶证书？已配对设备无需重新扫码。")) return;
				setBusy(true);
				try {
					await admin("certs.rotateLeaf");
					await Promise.all([refreshStatus(), loadPairing()]);
					setError(undefined);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					setBusy(false);
				}
			};

			const rotateCa = async () => {
				if (!window.confirm("轮换 CA 会归档旧证书并撤销全部已配对设备，所有手机都必须重新扫码配对。确认继续？")) return;
				if (!window.confirm("再次确认：这会立即断开所有手机连接。")) return;
				setBusy(true);
				try {
					await admin("certs.rotateCa", { confirm: "ROTATE-CA" });
					await Promise.all([refreshStatus(), loadPairing()]);
					setError(undefined);
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					setBusy(false);
				}
			};

			const sendTestNotification = async () => {
				setBusy(true);
				try {
					const result = await admin("apns.test");
					const failures = (result.results ?? []).filter((entry) => entry.ok !== true);
					if (result.mode === "ready" && result.delivered === 0 && failures.length === 0) {
						setError("APNs 已配置，但没有已注册的 push token：" + String(result.reason ?? "请先在手机上配对并注册通知"));
					} else if (failures.length > 0) {
						setError(
							"APNs 发送失败：" +
								failures
									.map((entry) => String(entry.status ?? "") + " " + String(entry.reason ?? entry.error ?? "unknown"))
									.join("；"),
						);
					} else if (result.mode !== "ready") {
						setError("APNs 当前为 " + String(result.mode) + " 模式：" + String(result.reason ?? "未配置"));
					} else {
						setError(undefined);
					}
				} catch (caught) {
					setError(String(caught?.message ?? caught));
				} finally {
					setBusy(false);
				}
			};

			const secondsLeft = (() => {
				const expiresAt = pairing?.status?.expiresAt;
				if (typeof expiresAt !== "number") return 0;
				return Math.max(0, Math.ceil((expiresAt - now) / 1000));
			})();

			const ready = status?.ready === true;
			const contract = status?.contract;
			const tls = status?.tls ?? {};
			const apns = status?.apns ?? {};

			return h(
				"div",
				{ style: styles.panel, "data-dshm-panel": "dsh-m-link" },
				h(
					"div",
					null,
					h("h2", { style: styles.h2 }, "DSH-m 手机连接"),
					h(
						"p",
						{ style: styles.sub },
						ready
							? "手机与这台 Mac 处于同一网络时，用 DSH-m App 扫描二维码即可连接。"
							: "插件尚未就绪：修复下方问题后重新打开本页。",
					),
				),
				error !== undefined
					? h("div", { style: styles.banner }, "无法读取插件状态：" + error)
					: null,
				contract !== undefined && contract?.ok === false
					? h(
							"div",
							{ style: styles.banner },
							h("strong", null, "当前 DSH 版本不兼容"),
							h("div", null, String(contract.error ?? "契约自检失败")),
							h("div", { style: { opacity: 0.7, marginTop: "4px" } }, "插件依赖 DSH 的 /connect 契约（301 重定向 + cookie + /api/remote.mux）。升级 DSH 后请更新 dsh-m-link，或回退到兼容版本。"),
						)
					: null,
				h(
					"div",
					{ style: styles.card },
					h(
						"div",
						{ style: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "12px" } },
						h("span", { style: { fontWeight: 600 } }, h(StatusDot, { ready, contract, started: status?.started }), ready ? "服务在线" : "服务未就绪"),
						h("span", { style: styles.sub }, "v" + String(status?.version ?? "…") + " · TLS 端口 " + String(tls.port ?? "—")),
					),
				),
				h(
					"div",
					{ style: styles.card, "data-dshm-pair-code-card": "" },
					h(
						"div",
						{ style: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "12px" } },
						h("span", { style: { fontWeight: 600 } }, "配对码"),
						h(
							"span",
							{ style: styles.sub },
							pairCode?.locked === true ? "错误次数过多，已作废" : codeValue ? "手机 App → 输入配对码（无需扫码）" : "正在生成配对码…",
						),
					),
					h(
						"div",
						{ style: styles.pairCodeRow },
						h(
							"span",
							{
								style: codeExpired || codeValue === "" ? { ...styles.pairCodeDigits, ...styles.pairCodeExpired } : styles.pairCodeDigits,
								"data-dshm-pair-code": codeValue,
								"data-dshm-pair-code-expires": codeExpiresAt === undefined ? undefined : String(codeExpiresAt),
							},
							codeGrouped,
						),
						h(Button, { onClick: refreshCode, disabled: busy, variant: "primary" }, "刷新配对码"),
					),
					h("div", { style: styles.progressTrack }, h("div", { style: styles.progressFill(codePercent, pairCode?.locked === true ? "#e5484d" : "#30a46c") })),
					h(
						"div",
						{ style: { ...styles.sub, display: "flex", justifyContent: "space-between", gap: "12px", flexWrap: "wrap" } },
						h("span", null, codeExpired ? "已过期，正在自动刷新…" : codeValue ? "剩余 " + String(Math.ceil(codeRemainingMs / 1000)) + " 秒" : "—"),
						h("span", null, "输错 " + String(pairCode?.maxAttempts ?? 5) + " 次作废 · 剩余 " + String(pairCode?.attemptsLeft ?? "—") + " 次"),
					),
					h("div", { style: { ...styles.sub, marginTop: "2px" } }, "码 2 分钟有效，仅可用一次；点「刷新配对码」立即更换。手机与 Mac 同一 Wi-Fi 时可自动发现，或已配置远程服务器时经公网配对。"),
				),
				h(RemoteRelayCard, null),
				h(
					"div",
					{ style: styles.grid },
					h(
						"div",
						{ style: { ...styles.card, ...styles.qrBox } },
						pairing?.qr?.ok === true
							? h(
									"button",
									{
										type: "button",
										style: styles.qrButton,
										onClick: () => setQrZoom(true),
										title: "点击放大二维码",
										"aria-label": "放大配对二维码",
										"data-dshm-qr-zoom": "trigger",
									},
									h("img", { src: pairing.qr.dataUrl, style: styles.qrImg, alt: "配对二维码", "data-dshm-qr": "pair" }),
								)
							: h("div", { style: styles.qrPlaceholder }, pairing?.qr?.error ? "二维码渲染不可用：" + pairing.qr.error : "正在生成二维码…"),
						secondsLeft > 0
							? h("div", { style: styles.sub }, "二维码 " + String(secondsLeft) + " 秒后过期" + (pairing?.qr?.ok === true ? " · 点击放大" : ""))
							: h("div", { style: styles.sub }, ready ? "二维码已过期，点击刷新" : "—"),
						h("div", { style: { display: "flex", gap: "8px" } },
							h(Button, { onClick: refreshPairing, disabled: busy, variant: "primary" }, "刷新二维码"),
							h(Button, {
								onClick: async () => {
									try {
										await navigator.clipboard.writeText(String(pairing?.payloadText ?? ""));
									} catch {
 /* ignore */
									}
								},
							}, "复制配对信息"),
						),
						h("div", { style: { ...styles.sub, textAlign: "center" } }, "二维码只在这里显示；配对一个手机后请刷新。"),
					),
					h(
						"div",
						{ style: styles.grow },
						h(
							"div",
							{ style: styles.card },
							h("div", { style: { ...styles.label, marginBottom: "4px" } }, "连接信息"),
							h(Row, { label: "监听地址", first: true }, h("span", { style: styles.mono }, (tls.bindHost ?? "—") + ":" + String(tls.port ?? "—"))),
							h(Row, { label: "CA 指纹 (SPKI pin)", mono: true }, h(CopyValue, { value: shortenFingerprint(tls.caPin), text: tls.caPin })),
							h(Row, { label: "叶证书 SHA-256", mono: true }, h(CopyValue, { value: shortenFingerprint(tls.leafFingerprint256), text: tls.leafFingerprint256 })),
							h(Row, { label: "叶证书到期" }, String(tls.leafNotAfter ?? "—")),
							h(
								Row,
								{ label: "手机可见 origin" },
								(status?.deviceEndpoints ?? status?.endpoints ?? []).map((endpoint) => endpoint.url).join(" · ") || "—",
							),
							(() => {
								const deviceUrls = (status?.deviceEndpoints ?? []).map((endpoint) => endpoint.url);
								const localOnly = (status?.endpoints ?? []).map((endpoint) => endpoint.url).filter((url) => !deviceUrls.includes(url));
								return localOnly.length === 0
									? null
									: h(Row, { label: "本机 origin（不发给手机）" }, localOnly.join(" · "));
							})(),
							(() => {
								const tunnel = status?.tunnel;
								if (tunnel === undefined || tunnel === null) {
									return h(Row, { label: "远程服务器" }, "未配置（LAN 直连；可选：在插件 tunnel.enabled 开启后经自建中继）");
								}
								const tunnelState =
									tunnel.state === "ready"
										? "已连接 · " + String(tunnel.origin ?? "—")
										: tunnel.state === "connecting"
											? "连接中…"
											: tunnel.state === "error"
												? "连接失败：" + String(tunnel.lastError ?? "unknown")
												: tunnel.state === "disabled"
													? "未启用"
													: String(tunnel.state ?? "未知");
								return h(Row, { label: "远程服务器" }, tunnelState);
							})(),
							h(
								Row,
								{ label: "局域网发现 (Bonjour)" },
								status?.bonjour?.enabled === false
									? "已关闭（bonjour.enabled=false）"
									: status?.bonjour?.active === true
										? "已广播 _dshm._tcp" + (status?.bonjour?.instance ? " · " + String(status.bonjour.instance) : "")
										: "未启用（仅在 bindHost=0.0.0.0 时广播）",
							),
							h(
								Row,
								{ label: "APNs 推送" },
								apns.mode === "ready"
									? "已配置 (" + String(apns.environment ?? "production") + ")" + (apns.topic ? " · topic " + String(apns.topic) : "")
									: apns.mode === "stub"
										? "stub（未配置，仅记录）"
										: "错误：" + String(apns.reason ?? "unknown"),
							),
						),
						h(
							"div",
							{ style: styles.card },
							h("div", { style: { display: "flex", alignItems: "center", justifyContent: "space-between" } },
								h("span", { style: { ...styles.label, marginBottom: "4px" } }, "已配对设备 (" + String(activeDevices.length) + ")"),
								h("span", { style: styles.sub }, "撤销后该设备立即断开并拉黑"),
							),
							activeDevices.length === 0
								? h("div", { style: { ...styles.sub, padding: "8px 0 2px" } }, "还没有已配对设备。")
								: activeDevices.map((device) =>
										h(
											"div",
											{ key: device.deviceId, style: { ...styles.deviceRow, borderTop: "1px solid color-mix(in srgb, currentColor 8%, transparent)" } },
											h(
												"div",
												{ style: styles.deviceMeta },
												h("span", { style: styles.deviceName }, device.name),
												h(
													"span",
													{ style: { ...styles.sub, ...styles.mono } },
													"最近活跃 " + relativeTime(device.lastSeenAt),
												),
											),
											h(
												"div",
												{ style: { display: "flex", alignItems: "center", gap: "8px" } },
												h(
													"span",
													{ style: styles.badge, title: device.pushTokenFingerprint ? "APNs token ·" + device.pushTokenFingerprint : undefined },
													device.hasPushToken ? "在线 · 可推送" : "已配对",
												),
												confirmRevoke === device.deviceId
													? h("span", { style: { display: "flex", gap: "6px" } },
															h(Button, { variant: "danger", onClick: () => revoke(device.deviceId), disabled: busy }, "确认撤销"),
															h(Button, { onClick: () => setConfirmRevoke(undefined) }, "取消"),
														)
													: h(Button, { variant: "danger", onClick: () => setConfirmRevoke(device.deviceId), disabled: busy }, "撤销"),
											),
										),
									),
						),
						h(
							"div",
							{ style: styles.card },
							h(
								"div",
								{ style: { display: "flex", alignItems: "center", justifyContent: "space-between" } },
								h("span", { style: { ...styles.label, marginBottom: "4px" } }, "本地数据"),
								h("button", { type: "button", style: styles.linkButton, onClick: () => setShowAudit(!showAudit) }, showAudit ? "收起审计" : "查看审计"),
							),
							h(Row, { label: "设备注册表", first: true, mono: true }, String(status?.dataDir ?? "—") + "/devices.json"),
							h(Row, { label: "证书目录" }, "plugin-data/dsh-m-link/tls"),
							h(
								"div",
								{ style: { ...styles.row, ...styles.rowBorder, flexWrap: "wrap", justifyContent: "flex-start" } },
								h(Button, { onClick: rotateLeaf, disabled: busy, title: "同一 CA 重签叶证书，CA pin 不变" }, "重签叶证书"),
								h(Button, { onClick: rotateCa, disabled: busy, variant: "danger", title: "归档 CA 并撤销全部设备，需要所有手机重新配对" }, "轮换 CA"),
								h(Button, { onClick: sendTestNotification, disabled: busy, title: "通过 APNs 或 stub 发送一条测试通知" }, "发送测试通知"),
							),
							showAudit
								? h(
										"div",
										{ style: styles.auditList },
										audit.length === 0
											? h("div", { style: styles.sub }, "暂无审计记录")
											: audit.map((line, index) =>
													h(
														"div",
														{ key: String(index), style: styles.auditLine },
														String(line.ts ?? "") + "  " + String(line.event ?? "") + (line.deviceId ? "  " + String(line.deviceId).slice(0, 8) : ""),
													),
												),
									)
								: null,
						),
					),
				),
				qrZoom && pairing?.qr?.ok === true
					? h(
							"div",
							{
								style: styles.qrOverlay,
								onClick: () => setQrZoom(false),
								role: "dialog",
								"aria-modal": "true",
								"aria-label": "放大的配对二维码",
								"data-dshm-qr-overlay": "zoom",
							},
							h(
								"div",
								{ style: styles.qrOverlayCard, onClick: (event) => event.stopPropagation() },
								h("img", { src: pairing.qr.dataUrl, style: styles.qrOverlayImg, alt: "配对二维码（放大）", "data-dshm-qr": "pair-zoom" }),
								h("div", { style: styles.qrOverlayHint }, "手机 App 扫描此二维码 · 按 ESC 或点击空白处关闭"),
							),
						)
					: null,
				h(
					"p",
					{ style: styles.footer },
					"安全提示：手机配对后等同于本机 owner 权限（可执行命令）。手机丢失时请立即撤销设备。配对令牌仅在本页显示，不写入日志与磁盘" + (status?.debugEnabled ? "（当前实例开启了 debug 通道，仅用于联调）" : "") + "。",
				),
			);
		}

		const inject = ["slots"];

		function apply(ctx) {
			ctx.slots.inject("settings.section", () =>
				ctx.slots.register(
					{
						name: "settings.section",
						id: "dsh-m-link",
						order: 90,
						label: () => "DSH-m 手机连接",
						inject: () => ({}),
					},
					DshmPanel,
				),
			);
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	},
});