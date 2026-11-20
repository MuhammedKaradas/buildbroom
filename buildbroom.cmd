@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\buildbroom.ps1" %*
