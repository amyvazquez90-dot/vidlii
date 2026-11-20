<?php
    /**
     * Front router for PHP's built-in web server.
     * Mirrors the rewrite rules from .htaccess:
     *   /name            -> /name.php  (when such a script exists)
     *   anything else    -> index.php  (application front controller)
     */

    $root = __DIR__;
    chdir($root);

    $path = parse_url($_SERVER["REQUEST_URI"] ?? "/", PHP_URL_PATH);
    $path = is_string($path) ? rawurldecode($path) : "/";
    if ($path === "" || $path === false) $path = "/";

    // Never allow path traversal outside the document root
    if (str_contains($path, "\0") || str_contains($path, "..")) {
        http_response_code(400);
        echo "Bad Request";
        return true;
    }

    $target = realpath($root . $path);

    if ($target !== false && str_starts_with($target, $root) && is_file($target)) {
        if (strtolower(pathinfo($target, PATHINFO_EXTENSION)) !== "php") {
            return false; // let the built-in server stream static files
        }
        chdir(dirname($target));
        $_SERVER["SCRIPT_FILENAME"] = $target;
        $_SERVER["SCRIPT_NAME"] = $path;
        require $target;
        return true;
    }

    // Clean URL mapping (e.g. /watch -> watch.php)
    $script = $root . rtrim($path, "/") . ".php";
    if (is_file($script)) {
        chdir($root);
        $_SERVER["SCRIPT_FILENAME"] = $script;
        $_SERVER["SCRIPT_NAME"] = rtrim($path, "/") . ".php";
        require $script;
        return true;
    }

    // Application front controller
    chdir($root);
    $_SERVER["SCRIPT_FILENAME"] = $root . "/index.php";
    $_SERVER["SCRIPT_NAME"] = "/index.php";
    require $root . "/index.php";
    return true;
