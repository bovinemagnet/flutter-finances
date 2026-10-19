// Plain Java parity of the shared financial rules. No Spring dependencies:
// the Spring Boot BOM is used only to align test library versions.
plugins {
    `java-library`
}

description = "Money, journal validation and ledger rules shared with the Dart client via spec fixtures"

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(platform(libs.spring.boot.dependencies))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testImplementation("org.assertj:assertj-core")
    testImplementation("tools.jackson.core:jackson-databind")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.withType<JavaCompile>().configureEach {
    options.release = 25
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(listOf("-Xlint:all", "-Xlint:-serial", "-parameters"))
}

tasks.test {
    useJUnitPlatform()
    // Fixture files live outside the project; re-run when they change.
    inputs.dir(rootProject.layout.projectDirectory.dir("spec/fixtures"))
        .withPropertyName("specFixtures")
        .withPathSensitivity(PathSensitivity.RELATIVE)
}
