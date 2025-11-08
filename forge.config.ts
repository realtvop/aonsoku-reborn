import type { ForgeConfig } from "@electron-forge/shared-types";
import { MakerSquirrel } from "@electron-forge/maker-squirrel";
import { MakerZIP } from "@electron-forge/maker-zip";
import { MakerDMG } from "@electron-forge/maker-dmg";
import { MakerRpm } from "@electron-forge/maker-rpm";
import { MakerDeb } from "@electron-forge/maker-deb";
import { FusesPlugin } from "@electron-forge/plugin-fuses";
import { FuseV1Options, FuseVersion } from "@electron/fuses";

const config: ForgeConfig = {
    packagerConfig: {
        asar: true,
        icon: "./build/icon",
        extraResource: ["./resources"],
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
    rebuildConfig: {
        // Disable native module rebuilds - they fail due to network restrictions
        // and are not required for the app to function properly
        force: false,
        onlyModules: ["@skip-all"],
    },
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