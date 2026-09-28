// SPDX-License-Identifier: Apache-2.0
// Licensed to the Ed-Fi Alliance under one or more agreements.
// The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
// See the LICENSE and NOTICES files in the project root for more information.

(function () {
    const DEFAULT_DMS_BASE_PATH = '/api';

    // Normalizes a configured base path: "" or an unsubstituted "${...}" falls back to the
    // default, "/" means "DMS at the site root", and any other value gets a leading slash and no
    // trailing slash. Examples: "api" -> "/api", "/api/" -> "/api", "/" -> "".
    const normalizeBasePath = (value, fallback) => {
        let path = typeof value === 'string' ? value.trim() : '';
        if (path.length === 0 || /^\$\{.*\}$/.test(path)) {
            path = fallback;
        }
        if (path === '/') {
            return '';
        }
        path = path.replace(/\/+$/, '');
        return path.startsWith('/') ? path : `/${path}`;
    };

    const dmsBasePath = normalizeBasePath(window.DMS_BASE_PATH, DEFAULT_DMS_BASE_PATH);

    // Absolute, same-origin URL for a path under the DMS base path, e.g.
    // dmsUrl('/metadata/specifications') -> "https://localhost/api/metadata/specifications".
    const dmsUrl = (path) => `${window.location.origin}${dmsBasePath}${path || ''}`;

    // Rewrites an absolute URL that DMS generated with an internal origin (for example
    // "http://dms:8080/api/data/..." or "http://localhost:8080/api/..." when forwarded headers are
    // not honored) onto the browser's origin. Only URLs whose path is under the DMS base path are
    // rewritten; everything else, including relative URLs, is returned unchanged.
    const toSameOrigin = (url) => {
        if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) {
            return url;
        }

        let parsed;
        try {
            parsed = new URL(url);
        } catch (error) {
            return url;
        }

        if (parsed.origin === window.location.origin) {
            return url;
        }

        const underBasePath = dmsBasePath === ''
            || parsed.pathname === dmsBasePath
            || parsed.pathname.startsWith(`${dmsBasePath}/`);
        if (!underBasePath) {
            return url;
        }

        return `${window.location.origin}${parsed.pathname}${parsed.search}${parsed.hash}`;
    };

    window.EdfiCommonHelper = {
        // Helper function to safely get values from schema
        safeGet: (schema, key) => {
            if (!schema) {
                return undefined;
            }
            if (typeof schema.get === 'function') {
                return schema.get(key);
            }
            // Fallback for plain objects
            return schema[key];
        },
        dmsBasePath,
        dmsUrl,
        // The DMS token endpoint as seen by the browser (behind NGINX: /api/oauth/token).
        dmsTokenUrl: () => dmsUrl('/oauth/token'),
        toSameOrigin,
    };
})();
