@echo off
chcp 65001 >nul
title 寻祎居 · 算力底牌侧写 (一键检测)
echo ==========================================================
echo   寻祎居 · 算力底牌侧写 (你是谁 · AI 眼里的这台电脑)
echo   只读扫描 · 零联网 · 不改系统 · 自动打开可视化侧写网页
echo ==========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI_PC_Environment_Audit.ps1"
echo.
echo 如果浏览器没有自动弹出，请直接打开文件夹里的：
echo   AI_PC_Audit_Result\index.html
echo.
pause
