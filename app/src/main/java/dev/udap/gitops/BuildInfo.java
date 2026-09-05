package dev.udap.gitops;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Build identity surfaced to the landing page and the /api/info endpoint.
 *
 * IMAGE_TAG is injected by the Helm chart from the container image tag, which
 * Argo CD sets as a Helm parameter on the Application object. Seeing the commit
 * SHA change here is the end-to-end proof that a GitOps deploy landed.
 */
@Component
public class BuildInfo {

    private final String appName;
    private final String imageTag;

    public BuildInfo(
            @Value("${app.name:gitops-delivery-platform}") String appName,
            @Value("${app.imageTag:dev}") String imageTag) {
        this.appName = appName;
        this.imageTag = imageTag;
    }

    public String getAppName() {
        return appName;
    }

    public String getImageTag() {
        return imageTag;
    }
}
