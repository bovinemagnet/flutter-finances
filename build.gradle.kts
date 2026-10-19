// Root build. The server subprojects configure themselves; documentation
// tasks (for example Antora) can be added here without touching them.
plugins {
    alias(libs.plugins.spring.boot) apply false
    alias(libs.plugins.spring.dependency.management) apply false
}

allprojects {
    group = "com.paulsnow.finance"
    version = "0.0.0"
}
