@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\devsweep.ps1" %*
