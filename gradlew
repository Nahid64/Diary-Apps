#!/bin/sh
# Launcher: uses the Gradle wrapper jar when present (the CI workflow generates it),
# otherwise falls back to a Gradle installed on PATH.
DIR=$(cd "$(dirname "$0")" && pwd)
JAR="$DIR/gradle/wrapper/gradle-wrapper.jar"
cd "$DIR" || exit 1
if [ -f "$JAR" ]; then
  exec java -classpath "$JAR" org.gradle.wrapper.GradleWrapperMain "$@"
else
  exec gradle "$@"
fi
