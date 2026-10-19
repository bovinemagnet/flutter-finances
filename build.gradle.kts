// Root build. The server subprojects configure themselves; the root adds
// the Antora documentation build (`gradle25w antora`).
plugins {
    alias(libs.plugins.spring.boot) apply false
    alias(libs.plugins.spring.dependency.management) apply false
    alias(libs.plugins.antora)
}

antora {
    version = libs.versions.antora.cli.get()
    playbook = file("antora-playbook.yml")
    options = listOf("--clean", "--fetch", "--stacktrace")
}

allprojects {
    group = "com.paulsnow.finance"
    version = "0.0.0"
}
