@echo off
setlocal
pushd "%~dp0"
where npm >nul 2>&1
if errorlevel 1 goto failed
call npm ci
if errorlevel 1 goto failed
call npx supabase start
if errorlevel 1 goto failed
call npx supabase migration up --local
if errorlevel 1 goto failed
call npm run db:setup-demo
if errorlevel 1 goto failed
call npm run dev
if errorlevel 1 goto failed
popd
exit /b 0
:failed
echo.
echo Setup stopped. Check that Node.js and Docker Desktop are running, then review the message above.
pause
popd
exit /b 1
