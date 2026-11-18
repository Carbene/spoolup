@echo off
rem Spoolup for Windows: starts the collector and opens the dashboard in your browser.
rem Double-click to run; if Spoolup is already running it just opens the dashboard.
rem Requires Node.js 22+ (https://nodejs.org). Close this window to stop Spoolup.
where node >nul 2>nul || (echo Node.js not found. Install it from https://nodejs.org and try again. & pause & exit /b 1)
title Spoolup
node "%~dp0server\spoolup.mjs" --open
if errorlevel 1 pause
