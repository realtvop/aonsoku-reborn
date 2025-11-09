import type { ForgeConfig } from "@electron-forge/shared-types";
import { MakerSquirrel } from "@electron-forge/maker-squirrel";
import { MakerZIP } from "@electron-forge/maker-zip";
import { MakerDMG } from "@electron-forge/maker-dmg";
import { MakerRpm } from "@electron-forge/maker-rpm";
import { MakerDeb } from "@electron-forge/maker-deb";
import { FusesPlugin } from "@electron-forge/plugin-fuses";
import { FuseV1Options, FuseVersion } from "@electron/fuses";

const config: ForgeConfig = {
    // Use 'dist' instead of 'out' to avoid conflict with electron-vite's output directory
    outDir: "dist",
    packagerConfig: {
        asar: true,
        icon: "./build/icon",
        extraResource: ["./resources"],
        executableName: "aonsoku",
        // Use ARCH environment variable if set, otherwise use x64 as default
        arch: (process.env.ARCH as "ia32" | "x64" | "armv7l" | "arm64" | "mips64el" | "universal" | undefined) || "x64",
        // Custom ignore function to prevent ignoring the out/ directory
        // Since electron-vite outputs to "out/" and we changed Electron Forge's outDir to "dist/",
        // we need to ensure "out/" is not ignored during packaging
        ignore: (path: string) => {
            if (!path) return false;
            
            // Never ignore package.json (required for electron app)
            if (path === "/package.json") return false;
            
            // Never ignore out directory (contains electron-vite build output)
            if (path === "/out" || path.startsWith("/out/")) return false;
            
            // Never ignore resources directory (extra resources for the app)
            if (path === "/resources" || path.startsWith("/resources/")) return false;
            
            // Ignore node_modules and .git
            if (path.startsWith("/node_modules")) return true;
            if (path.startsWith("/.git")) return true;
            
            // Ignore source code directories
            if (path.startsWith("/src")) return true;
            if (path.startsWith("/electron")) return true;
            if (path.startsWith("/public")) return true;
            if (path.startsWith("/cypress")) return true;
            if (path.startsWith("/.vscode")) return true;
            if (path.startsWith("/.husky")) return true;
            if (path.startsWith("/build")) return true;
            if (path.startsWith("/media")) return true;
            if (path.startsWith("/scripts")) return true;
            if (path.startsWith("/dist")) return true;
            
            // Ignore development and config files
            if (path.endsWith(".ts")) return true;
            if (path.endsWith(".tsx")) return true;
            if (path.endsWith(".md")) return true;
            if (path.endsWith(".yml")) return true;
            if (path.endsWith(".yaml")) return true;
            if (path.includes("tsconfig")) return true;
            if (path.includes("pnpm-lock")) return true;
            if (path.includes("vite.config")) return true;
            if (path.includes("electron.vite.config")) return true;
            if (path.includes("forge.config")) return true;
            
            // Allow everything else
            return false;
        },
        win32metadata: {
            CompanyName: "realtvop",
            ProductName: "Aonsoku",
        },
        osxSign: {
            identity: process.env.APPLE_IDENTITY,
            "hardened-runtime": true,
            "entitlements": "./build/entitlements.mac.plist",
            "entitlements-inherit": "./build/entitlements.mac.plist",
            "signature-flags": "library",
        },
        osxNotarize: process.env.APPLE_ID
            ? {
                appleId: process.env.APPLE_ID,
                appleIdPassword: process.env.APPLE_ID_PASSWORD,
                teamId: process.env.APPLE_TEAM_ID,
            }
            : undefined,
    },
    rebuildConfig: {},
    makers: [
        new MakerSquirrel(
            {
                certificateFile: process.env.WINDOWS_CERTIFICATE_FILE,
                certificatePassword: process.env.WINDOWS_CERTIFICATE_PASSWORD,
                signWithParams: `/f "${process.env.WINDOWS_CERTIFICATE_FILE}" /p "${process.env.WINDOWS_CERTIFICATE_PASSWORD}" /tr http://timestamp.digicert.com /td sha256`,
            },
            ["win32"]
        ),
        new MakerZIP({}, ["darwin"]),
        new MakerDMG({
            format: "ULFO",
            icon: "./build/icon.icns",
        }),
        new MakerRpm({
            options: {
                homepage: "https://github.com/realtvop/aonsoku-reborn",
                categories: ["AudioVideo", "Audio"],
            },
        }),
        new MakerDeb({
            options: {
                homepage: "https://github.com/realtvop/aonsoku-reborn",
            },
        }),
    ],
    plugins: [
        new FusesPlugin({
            version: FuseVersion.V1,
            [FuseV1Options.RunAsNode]: false,
            [FuseV1Options.EnableNodeCliInspectArguments]: false,
            [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
        }),
    ],
    publishers: [
        {
            name: "@electron-forge/publisher-github",
            config: {
                repository: {
                    owner: "realtvop",
                    name: "aonsoku-reborn",
                },
                prerelease: false,
                draft: true,
            },
        },
    ],
};

export default config;