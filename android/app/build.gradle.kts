import groovy.json.JsonSlurper
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import javax.inject.Inject

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val releaseSigning: Map<String, String?> = listOf(
    "aonsokuReleaseStoreFile",
    "aonsokuReleaseStorePassword",
    "aonsokuReleaseKeyAlias",
    "aonsokuReleaseKeyPassword",
).associateWith { name -> providers.gradleProperty(name).orNull?.trim() }
val releaseSigningConfigured = releaseSigning.values.none { it.isNullOrEmpty() }

// The product version shown in the app follows the repository package.json,
// which nightly and release workflows rewrite before building.
val repositoryRoot: File = rootProject.projectDir.parentFile

@Suppress("UNCHECKED_CAST")
val packageJson =
    JsonSlurper().parse(File(repositoryRoot, "package.json")) as Map<String, Any?>
val productVersion = packageJson["version"].toString()
val gitShortHash: String = providers.exec {
    commandLine("git", "rev-parse", "--short", "HEAD")
    workingDir = repositoryRoot
    isIgnoreExitValue = true
}.standardOutput.asText.map { it.trim() }.getOrElse("")

// Debug builds keep a fixed timestamp so BuildConfig stays cacheable.
val isReleaseBuild = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
val buildTimestamp = if (isReleaseBuild) System.currentTimeMillis() else 0L

// Assets shared with the web app have one source of truth in the repository:
// translations (src/i18n/locales) and the brand typeface (public/fonts). They
// are packaged as i18n/<locale>.json and fonts/<name>.ttf.
abstract class SyncSharedAssetsTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val localesDir: DirectoryProperty

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fontsDir: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Inject
    abstract val fileSystem: FileSystemOperations

    @TaskAction
    fun sync() {
        fileSystem.sync {
            from(localesDir) {
                include("*.json")
                into("i18n")
            }
            from(fontsDir) {
                include(
                    "Poppins-Regular.ttf",
                    "Poppins-Medium.ttf",
                    "Poppins-SemiBold.ttf",
                    "Poppins-Bold.ttf",
                )
                into("fonts")
            }
            into(outputDir)
        }
    }
}

val syncSharedAssets = tasks.register<SyncSharedAssetsTask>("syncAonsokuSharedAssets") {
    localesDir.set(File(repositoryRoot, "src/i18n/locales"))
    fontsDir.set(File(repositoryRoot, "public/fonts"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            syncSharedAssets,
            SyncSharedAssetsTask::outputDir,
        )
    }
}

android {
    namespace = "github.realtvop.aonsoku"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "github.realtvop.aonsoku"
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        // Rewritten by `capacitor-set-version` when a release is tagged.
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "APP_VERSION", "\"$productVersion\"")
        buildConfigField("String", "BUILD_HASH", "\"$gitShortHash\"")
        buildConfigField("long", "BUILD_TIME", "${buildTimestamp}L")
        buildConfigField(
            "String",
            "REPOSITORY_URL",
            "\"https://github.com/realtvop/aonsoku-reborn\"",
        )
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = file(releaseSigning.getValue("aonsokuReleaseStoreFile")!!)
                storePassword = releaseSigning["aonsokuReleaseStorePassword"]
                keyAlias = releaseSigning["aonsokuReleaseKeyAlias"]
                keyPassword = releaseSigning["aonsokuReleaseKeyPassword"]
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests {
            // The Compose smoke tests run on Robolectric against the real
            // resources, locale files, and fonts.
            isIncludeAndroidResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_21
        optIn.addAll(
            "androidx.compose.material3.ExperimentalMaterial3Api",
            "androidx.compose.material3.ExperimentalMaterial3ExpressiveApi",
            "androidx.compose.foundation.ExperimentalFoundationApi",
            "androidx.compose.foundation.layout.ExperimentalLayoutApi",
            "androidx.compose.animation.ExperimentalSharedTransitionApi",
            "kotlinx.coroutines.ExperimentalCoroutinesApi",
            "kotlinx.coroutines.FlowPreview",
        )
    }
}

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    val configured = releaseSigningConfigured
    val keystorePath = releaseSigning["aonsokuReleaseStoreFile"]
    doLast {
        if (!configured) {
            throw GradleException(
                "Release signing is not configured. Set the aonsokuRelease* Gradle properties.",
            )
        }
        val keystore = File(keystorePath!!)
        if (!keystore.isFile) {
            throw GradleException("Release keystore does not exist: $keystore")
        }
    }
}

tasks.matching { it.name in setOf("assembleRelease", "bundleRelease") }.configureEach {
    dependsOn(verifyReleaseSigning)
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.palette)
    implementation(libs.material)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.animation)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.coil.compose)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.org.json)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.robolectric)
}
