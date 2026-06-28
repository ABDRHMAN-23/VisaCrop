const SERVER = typeof window !== "undefined"
  ? (localStorage.getItem("tradepro_server") || "http://localhost:3000")
  : "http://localhost:3000";

export async function pushData(userId, data) {
  try {
    const r = await fetch(`${SERVER}/api/sync/${userId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ data: { ...data, lastSaved: new Date().toISOString() } }),
      signal: AbortSignal.timeout(5000),
    });
    return await r.json();
  } catch { return { status: "offline" }; }
}

export async function pullData(userId) {
  try {
    const r = await fetch(`${SERVER}/api/sync/${userId}`, {
      signal: AbortSignal.timeout(5000),
    });
    return await r.json();
  } catch { return { status: "offline" }; }
}

export function createSync(userId, onUpdate, onStatus) {
  const wsUrl = SERVER.replace(/^http/, "ws");
  let ws, retries = 0, closed = false;

  function connect() {
    if (closed) return;
    try {
      ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        retries = 0;
        ws.send(JSON.stringify({ type: "register", userId }));
        onStatus?.("connected");
      };

      ws.onmessage = (e) => {
        try {
          const msg = JSON.parse(e.data);
          if ((msg.type === "sync" || msg.type === "init") && msg.data) {
            onUpdate(msg.data);
          }
        } catch {}
      };

      ws.onclose = () => {
        onStatus?.("disconnected");
        if (!closed) {
          const delay = Math.min(1000 * 2 ** retries, 30000);
          retries++;
          setTimeout(connect, delay);
        }
      };

      ws.onerror = () => ws.close();
    } catch {}
  }

  connect();

  return {
    push: (data) => {
      if (ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "update", userId, data }));
      }
    },
    close: () => { closed = true; ws?.close(); },
  };
}

export function useServerSync(state, setState, userId) {
  const syncRef = { current: null };
  const pushRef = { current: 0 };

  function init() {
    if (!userId || typeof window === "undefined") return;

    pullData(userId).then(res => {
      if (res.status === "ok" && res.data) {
        const srv = new Date(res.data.lastSaved || 0);
        const loc = new Date(state.lastSaved || 0);
        if (srv > loc) setState(res.data);
      }
    });

    syncRef.current = createSync(
      userId,
      (serverData) => {
        const srv = new Date(serverData.lastSaved || 0);
        const loc = new Date(state.lastSaved || 0);
        if (srv > loc) setState(serverData);
      },
      (status) => console.log("[Sync]", status)
    );

    return () => syncRef.current?.close();
  }

  function onStateChange() {
    if (!userId) return;
    const now = Date.now();
    if (now - pushRef.current < 2000) return;
    pushRef.current = now;
    const d = { ...state, lastSaved: new Date().toISOString() };
    pushData(userId, d);
    syncRef.current?.push(d);
  }

  return { init, onStateChange };
}
