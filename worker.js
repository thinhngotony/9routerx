export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    let version = "latest";
    try {
      const release = await fetch(
        "https://api.github.com/repos/thinhngotony/9routerx/releases/latest",
        {
          headers: { "User-Agent": "9routerx-worker" },
          cf: { cacheTtl: 60 },
        },
      );
      if (release.ok) {
        const data = await release.json();
        version = data.tag_name || "latest";
      }
    } catch {
      // Fallback to main if release lookup fails.
    }

    const ref = version !== "latest" ? version : "main";
    const base = `https://raw.githubusercontent.com/thinhngotony/9routerx/${ref}`;

    const routes = {
      "/install": `${base}/install-universal.sh`,
      "/install.sh": `${base}/scripts/install.sh`,
      "/sync.py": `${base}/scripts/sync/9router_claude_sync.py`,
      "/sync-cron.sh": `${base}/scripts/sync/install_sync_cron.sh`,
    };

    if (path === "/") {
      const displayVersion = version.replace(/^v/, "");
      return new Response(
        `9routerx API v${displayVersion}

Install:
  curl -sfS https://9routerx.hyberorbit.com/install | sh

Raw scripts:
  /install.sh
  /sync.py
  /sync-cron.sh

Documentation: https://github.com/thinhngotony/9routerx
`,
        { headers: { "Content-Type": "text/plain" } },
      );
    }

    const targetUrl = routes[path];
    if (!targetUrl) {
      return new Response("Not found", { status: 404 });
    }

    const response = await fetch(targetUrl, {
      cf: { cacheTtl: 0, cacheEverything: false },
    });

    return new Response(response.body, {
      status: response.status,
      headers: {
        "Content-Type": "text/plain",
        "Cache-Control": "no-cache, no-store, must-revalidate",
        Pragma: "no-cache",
        Expires: "0",
        "Access-Control-Allow-Origin": "*",
      },
    });
  },
};

