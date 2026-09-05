package dev.udap.gitops;

import java.util.Map;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * `/` serves a human-visible HTML landing page (per platform convention the home
 * route is a UI, not a JSON document). `/api/info` is the machine-readable
 * equivalent used by the tests.
 */
@RestController
public class HomeController {

    private final BuildInfo buildInfo;

    public HomeController(BuildInfo buildInfo) {
        this.buildInfo = buildInfo;
    }

    @GetMapping(value = "/", produces = MediaType.TEXT_HTML_VALUE)
    public String home() {
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>%s</title>
              <style>
                :root { color-scheme: dark; }
                body {
                  margin: 0; min-height: 100vh; display: grid; place-items: center;
                  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
                  background: radial-gradient(circle at 30%% 20%%, #1e293b, #0f172a 60%%);
                  color: #e2e8f0;
                }
                .card {
                  background: rgba(15, 23, 42, .75); border: 1px solid #334155;
                  border-radius: 14px; padding: 2.5rem 3rem; max-width: 40rem;
                  box-shadow: 0 20px 60px rgba(0,0,0,.45);
                }
                h1 { margin: 0 0 .25rem; font-size: 1.6rem; letter-spacing: -.02em; }
                p.sub { margin: 0 0 1.75rem; color: #94a3b8; font-size: .95rem; }
                dl { display: grid; grid-template-columns: auto 1fr; gap: .6rem 1.25rem; margin: 0; }
                dt { color: #64748b; font-size: .8rem; text-transform: uppercase; letter-spacing: .06em; }
                dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9rem; }
                .flow { margin-top: 1.75rem; padding-top: 1.25rem; border-top: 1px solid #334155;
                        color: #94a3b8; font-size: .85rem; line-height: 1.6; }
                .pill { display: inline-block; background: #134e4a; color: #5eead4;
                        border-radius: 999px; padding: .15rem .6rem; font-size: .75rem; }
              </style>
            </head>
            <body>
              <main class="card">
                <h1>%s</h1>
                <p class="sub"><span class="pill">GitOps</span> delivered by Argo CD on Amazon EKS</p>
                <dl>
                  <dt>Image tag</dt><dd>%s</dd>
                  <dt>Delivery</dt><dd>Argo CD &rarr; Helm &rarr; Deployment</dd>
                  <dt>Health</dt><dd><a style="color:#5eead4" href="/actuator/health">/actuator/health</a></dd>
                </dl>
                <p class="flow">
                  This page is rendered by the image whose tag is shown above. CI pushed that
                  image to ECR tagged with the commit SHA, then patched the tag onto the Argo CD
                  Application as a Helm parameter &mdash; the repository itself was never modified,
                  so self-heal has nothing to fight.
                </p>
              </main>
            </body>
            </html>
            """.formatted(buildInfo.getAppName(), buildInfo.getAppName(), buildInfo.getImageTag());
    }

    @GetMapping(value = "/api/info", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, String> info() {
        return Map.of(
                "app", buildInfo.getAppName(),
                "imageTag", buildInfo.getImageTag());
    }
}
