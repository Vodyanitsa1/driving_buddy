allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Paksa semua plugin subproject (termasuk audioplayers_android) compile dengan SDK 36
subprojects {
    val configureAction: (Project) -> Unit = { proj ->
        val ext = proj.extensions.findByName("android")
        if (ext is com.android.build.gradle.LibraryExtension) {
            ext.compileSdk = 36
        }
    }
    if (project.state.executed) {
        configureAction(project)
    } else {
        project.afterEvaluate(configureAction)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
