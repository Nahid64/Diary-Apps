@echo off
set DIR=%~dp0
set JAR=%DIR%gradle\wrapper\gradle-wrapper.jar
cd /d "%DIR%"
if exist "%JAR%" (
  java -classpath "%JAR%" org.gradle.wrapper.GradleWrapperMain %*
) else (
  gradle %*
)
