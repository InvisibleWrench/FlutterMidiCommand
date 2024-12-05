import java.io.ByteArrayOutputStream

rootProject.buildDir = File("../build")

subprojects {
  buildDir = File(rootProject.buildDir, name)
}

subprojects {
  evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
  delete(rootProject.buildDir)
}
