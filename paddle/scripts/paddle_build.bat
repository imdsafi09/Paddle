@ECHO ON
SETLOCAL

rem Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
rem
rem Licensed under the Apache License, Version 2.0 (the "License");
rem you may not use this file except in compliance with the License.
rem You may obtain a copy of the License at
rem
rem     http://www.apache.org/licenses/LICENSE-2.0
rem
rem Unless required by applicable law or agreed to in writing, software
rem distributed under the License is distributed on an "AS IS" BASIS,
rem WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
rem See the License for the specific language governing permissions and
rem limitations under the License.

rem =================================================
rem       Paddle CI Task On Windows Platform
rem =================================================

set work_dir=%cd%
if exist build rmdir build /s/q
mkdir build
cd /d build

rem ------initialize the virtual environment------
if not defined PYTHON_ROOT set PYTHON_ROOT=c:\Python37
set PYTHON_EXECUTABLE=%PYTHON_ROOT%\python.exe
%PYTHON_EXECUTABLE% -m pip install virtualenv
if not exist paddle_winci (%PYTHON_EXECUTABLE% -m virtualenv paddle_winci)
call paddle_winci\Scripts\activate.bat
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

rem ------pre install requirement----------
where python
where pip
pip install --upgrade pip
pip install wheel
pip install gym
pip install -r %work_dir%\python\requirements.txt
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

rem ------initialize common variable------
if not defined CUDA_TOOLKIT_ROOT_DIR set CUDA_TOOLKIT_ROOT_DIR="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v10.0"
if not defined BRANCH set BRANCH=develop
if not defined WITH_AVX set WITH_AVX=ON
if not defined WITH_TESTING set WITH_TESTING=ON
if not defined WITH_PYTHON set WITH_PYTHON=ON
if not defined ON_INFER set ON_INFER=ON
if not defined WITH_INFERENCE_API_TEST set WITH_INFERENCE_API_TEST=OFF
if not defined WITH_TPCACHE set WITH_TPCACHE=ON

rem ------set cache third_party------
set cache_dir=%work_dir%\..\cache
dir %cache_dir%
set INFERENCE_DEMO_INSTALL_DIR=%cache_dir:\=/%/inference_demo

if not exist %cache_dir%\tools (
    git clone https://github.com/zhouwei25/tools %cache_dir%\tools
    if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%
)

if "%WITH_TPCACHE%"=="OFF" (
    set THIRD_PARTY_PATH=%work_dir:\=/%/build/third_party
    goto :CASE_%1
)

echo set -ex > cache.sh
echo md5_content=$(cat %work_dir:\=/%/cmake/external/*.cmake  ^|md5sum ^| awk '{print $1}') >> cache.sh
echo echo ${md5_content}^>md5.txt >> cache.sh

%cache_dir%\tools\busybox64.exe cat cache.sh
%cache_dir%\tools\busybox64.exe bash cache.sh

set /p md5=< md5.txt
if "%WITH_GPU%"=="ON" (
    set THIRD_PARTY_PATH=%cache_dir:\=/%/third_party_GPU/%md5%
) else (
    set THIRD_PARTY_PATH=%cache_dir:\=/%/third_party/%md5%
)

goto :CASE_%1

echo "Usage: paddle_build.bat [OPTION]"
echo "OPTION:"
echo "wincheck_mkl: run Windows MKL/GPU/UnitTest CI tasks on Windows"
echo "wincheck_openbals: run Windows OPENBLAS/CPU CI tasks on Windows"
exit /b 1

:CASE_wincheck_mkl
set WITH_MKL=ON
set WITH_GPU=OFF
call :cmake || goto cmake_error
call :build || goto build_error
call :test_whl_pacakage || goto test_whl_pacakage_error
call :unit_test || goto unit_test_error
call :test_inference || goto test_inference_error
call :check_change_of_unittest || goto check_change_of_unittest_error
goto:success

:CASE_wincheck_openblas
set WITH_MKL=OFF
set WITH_GPU=ON
call :cmake || goto cmake_error
call :build || goto build_error
call :test_whl_pacakage || goto test_whl_pacakage_error
goto:success

rem "Other configurations are added here"
rem :CASE_wincheck_others
rem call ...


rem ---------------------------------------------------------------------------------------------
:cmake
echo    ========================================
echo    Step 1. Cmake ...
echo    ========================================

echo cmake .. -G "Visual Studio 14 2015 Win64" -DWITH_AVX=%WITH_AVX% -DWITH_GPU=%WITH_GPU% -DWITH_MKL=%WITH_MKL% -DWITH_TESTING=%WITH_TESTING% -DWITH_PYTHON=%WITH_PYTHON% -DCUDA_TOOLKIT_ROOT_DIR=%CUDA_TOOLKIT_ROOT_DIR% -DON_INFER=%ON_INFER% -DTHIRD_PARTY_PATH=%THIRD_PARTY_PATH%
cmake .. -G "Visual Studio 14 2015 Win64" -DWITH_AVX=%WITH_AVX% -DWITH_GPU=%WITH_GPU% -DWITH_MKL=%WITH_MKL% -DWITH_TESTING=%WITH_TESTING% -DWITH_PYTHON=%WITH_PYTHON% -DCUDA_TOOLKIT_ROOT_DIR=%CUDA_TOOLKIT_ROOT_DIR% -DON_INFER=%ON_INFER% -DTHIRD_PARTY_PATH=%THIRD_PARTY_PATH%
goto:eof

:cmake_error
call paddle_winci\Scripts\deactivate.bat
echo cmake failed!
exit /b 1

rem ---------------------------------------------------------------------------------------------
:build
echo    ========================================
echo    Step 2. Buile Paddle ...
echo    ========================================
call "C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\vcvarsall.bat" amd64
set build_times=1

:build_tp
echo BUILD THIRD_PARTY %build_times%
msbuild /m /p:Configuration=Release /verbosity:quiet third_party.vcxproj
echo BUILD THIRD_PARTY RESULT %ERRORLEVEL%
if %ERRORLEVEL% NEQ 0 (
    set /a build_times=%build_times%+1  
    if %build_times% GTR 3 (
        exit /b 1
    ) else (
        goto :build_tp
    )
)

set build_times=1
:build_paddle
echo BUILD PADDLE %build_times%
msbuild /m /p:Configuration=Release /verbosity:quiet paddle.sln
echo BUILD PADDLE RESULT %ERRORLEVEL%
if %ERRORLEVEL% NEQ 0 (
    set /a build_times=%build_times%+1
    if %build_times% GTR 2 (
        exit /b 1
    ) else (
        goto :build_paddle
    )
)
goto:eof

:build_error
call paddle_winci\Scripts\deactivate.bat
echo build paddle failed!
exit /b 7

rem ---------------------------------------------------------------------------------------------
:test_whl_pacakage
echo    ========================================
echo    Step 3. Test pip install whl package ...
echo    ========================================
dir /s /b python\dist\*.whl > whl_file.txt
set /p PADDLE_WHL_FILE_WIN=< whl_file.txt

pip install -U %PADDLE_WHL_FILE_WIN%
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

echo import paddle.fluid;print(paddle.__version__) > test_whl.py
python test_whl.py
goto:eof

:test_whl_pacakage_error
call paddle_winci\Scripts\deactivate.bat
exit /b 3

rem ---------------------------------------------------------------------------------------------
:unit_test
echo    ========================================
echo    Step 4. Running unit tests ...
echo    ========================================

dir %THIRD_PARTY_PATH:/=\%\install\openblas\lib
dir %THIRD_PARTY_PATH:/=\%\install\openblas\bin
dir %THIRD_PARTY_PATH:/=\%\install\zlib\bin
dir %THIRD_PARTY_PATH:/=\%\install\mklml\lib
dir %THIRD_PARTY_PATH:/=\%\install\mkldnn\bin
dir %THIRD_PARTY_PATH:/=\%\install\warpctc\bin

set PATH=%THIRD_PARTY_PATH:/=\%\install\openblas\lib;%THIRD_PARTY_PATH:/=\%\install\openblas\bin;%THIRD_PARTY_PATH:/=\%\install\zlib\bin;%THIRD_PARTY_PATH:/=\%\install\mklml\lib;%THIRD_PARTY_PATH:/=\%\install\mkldnn\bin;%THIRD_PARTY_PATH:/=\%\install\warpctc\bin;%PATH%
ctest.exe --output-on-failure -C Release -j 7
goto:eof

:unit_test_error
call paddle_winci\Scripts\deactivate.bat
exit /b 8

rem ---------------------------------------------------------------------------------------------
:test_inference
echo    ========================================
echo    Step 5. Testing fluid library for inference ...
echo    ========================================

cd %work_dir%\paddle\fluid\inference\api\demo_ci

%cache_dir%\tools\busybox64.exe bash run.sh %work_dir:\=/% %WITH_MKL% %WITH_GPU% %cache_dir:\=/%/inference_demo
goto:eof

:test_inference_error
call paddle_winci\Scripts\deactivate.bats
echo Testing fluid library for inference failed!
exit /b 5

rem ---------------------------------------------------------------------------------------------
:check_change_of_unittest
echo    ========================================
echo    Step 6. Check whether deleting a unit test ...
echo    ========================================

set PATH=%PYTHON_ROOT%;%PATH%
cd /d %work_dir%\build
echo set -ex>  check_change_of_unittest.sh
echo GITHUB_API_TOKEN=%GITHUB_API_TOKEN% >>  check_change_of_unittest.sh
echo GIT_PR_ID=%AGILE_PULL_ID% >>  check_change_of_unittest.sh
echo BRANCH=%BRANCH%>>  check_change_of_unittest.sh
echo if [ "${GITHUB_API_TOKEN}" == "" ] ^|^| [ "${GIT_PR_ID}" == "" ];then>> check_change_of_unittest.sh
echo     exit 0 >>  check_change_of_unittest.sh
echo fi>>  check_change_of_unittest.sh
echo cat ^<^<EOF>>  check_change_of_unittest.sh
echo     ============================================ >>  check_change_of_unittest.sh
echo     Generate unit tests.spec of this PR.         >>  check_change_of_unittest.sh
echo     ============================================ >>  check_change_of_unittest.sh
echo EOF>>  check_change_of_unittest.sh
echo spec_path=$(pwd)/UNITTEST_PR.spec>>  check_change_of_unittest.sh
echo ctest -N ^| awk -F ':' '{print $2}' ^| sed '/^^$/d' ^| sed '$d' ^> ${spec_path}>>  check_change_of_unittest.sh
echo UPSTREAM_URL='https://github.com/PaddlePaddle/Paddle'>>  check_change_of_unittest.sh
echo origin_upstream_url=`git remote -v ^| awk '{print $1, $2}' ^| uniq ^| grep upstream ^| awk '{print $2}'`>>  check_change_of_unittest.sh
echo if [ "$origin_upstream_url" == "" ]; then>>  check_change_of_unittest.sh
echo     git remote add upstream $UPSTREAM_URL.git>>  check_change_of_unittest.sh
echo elif [ "$origin_upstream_url" != "$UPSTREAM_URL" ] \>>  check_change_of_unittest.sh
echo         ^&^& [ "$origin_upstream_url" != "$UPSTREAM_URL.git" ]; then>>  check_change_of_unittest.sh
echo     git remote remove upstream>>  check_change_of_unittest.sh
echo     git remote add upstream $UPSTREAM_URL.git>>  check_change_of_unittest.sh
echo fi>>  check_change_of_unittest.sh
echo if [ ! -e "$(pwd)/../.git/refs/remotes/upstream/$BRANCH" ]; then>>  check_change_of_unittest.sh
echo     git fetch upstream $BRANCH # develop is not fetched>>  check_change_of_unittest.sh
echo fi>>  check_change_of_unittest.sh
echo git checkout -b origin_pr >>  check_change_of_unittest.sh
echo git checkout -f $BRANCH >>  check_change_of_unittest.sh
echo cmake .. -G "Visual Studio 14 2015 Win64" -DWITH_AVX=%WITH_AVX% -DWITH_GPU=%WITH_GPU% -DWITH_MKL=%WITH_MKL% -DWITH_TESTING=%WITH_TESTING% -DWITH_PYTHON=%WITH_PYTHON% -DCUDA_TOOLKIT_ROOT_DIR=%CUDA_TOOLKIT_ROOT_DIR% -DON_INFER=%ON_INFER% -DTHIRD_PARTY_PATH=%THIRD_PARTY_PATH% >>  check_change_of_unittest.sh
echo cat ^<^<EOF>>  check_change_of_unittest.sh
echo     ============================================       >>  check_change_of_unittest.sh
echo     Generate unit tests.spec of develop.               >>  check_change_of_unittest.sh
echo     ============================================       >>  check_change_of_unittest.sh
echo EOF>>  check_change_of_unittest.sh
echo spec_path=$(pwd)/UNITTEST_DEV.spec>>  check_change_of_unittest.sh
echo ctest -N ^| awk -F ':' '{print $2}' ^| sed '/^^$/d' ^| sed '$d' ^> ${spec_path}>>  check_change_of_unittest.sh
echo unittest_spec_diff=`python $(pwd)/../tools/diff_unittest.py $(pwd)/UNITTEST_DEV.spec $(pwd)/UNITTEST_PR.spec`>>  check_change_of_unittest.sh
echo if [ "$unittest_spec_diff" != "" ]; then>>  check_change_of_unittest.sh
echo     # approval_user_list: XiaoguangHu01 46782768,luotao1 6836917,phlrain 43953930,lanxianghit 47554610, zhouwei25 52485244, kolinwei 22165420>>  check_change_of_unittest.sh
echo     approval_line=`curl -H "Authorization: token ${GITHUB_API_TOKEN}" https://api.github.com/repos/PaddlePaddle/Paddle/pulls/${GIT_PR_ID}/reviews?per_page=10000`>>  check_change_of_unittest.sh
echo     set +x>>  check_change_of_unittest.sh
echo     if [ "$approval_line" != "" ]; then>>  check_change_of_unittest.sh
echo         APPROVALS=`echo ${approval_line} ^|python $(pwd)/../tools/check_pr_approval.py 1 22165420 52485244 6836917`>>  check_change_of_unittest.sh
echo         echo "current pr ${GIT_PR_ID} got approvals: ${APPROVALS}">>  check_change_of_unittest.sh
echo         if [ "${APPROVALS}" == "FALSE" ]; then>>  check_change_of_unittest.sh
echo             echo "************************************"                >>  check_change_of_unittest.sh
echo             echo -e "It is forbidden to disable or delete the unit-test.\n"        >>  check_change_of_unittest.sh
echo             echo -e "If you must delete it temporarily, please add it to[https://github.com/PaddlePaddle/Paddle/wiki/Temporarily-disabled-Unit-Test]."     >>  check_change_of_unittest.sh
echo             echo -e "Then you must have one RD (kolinwei(recommended) or zhouwei25) approval for the deletion of unit-test. \n"                 >>  check_change_of_unittest.sh
echo             echo -e "If you have any problems about deleting unit-test, please read the specification [https://github.com/PaddlePaddle/Paddle/wiki/Deleting-unit-test-is-forbidden]. \n"   >>  check_change_of_unittest.sh
echo             echo -e "Following unit-tests are deleted in this PR: \n ${unittest_spec_diff} \n"     >>  check_change_of_unittest.sh
echo             echo "************************************"                >>  check_change_of_unittest.sh
echo             exit 1 >>  check_change_of_unittest.sh
echo          fi>>  check_change_of_unittest.sh
echo     else>>  check_change_of_unittest.sh
echo          exit 1 >>  check_change_of_unittest.sh
echo     fi>>  check_change_of_unittest.sh
echo fi>>  check_change_of_unittest.sh
echo git checkout -f origin_pr >>  check_change_of_unittest.sh
%cache_dir%\tools\busybox64.exe bash check_change_of_unittest.sh
goto:eof

:check_change_of_unittest_error
call paddle_winci\Scripts\deactivate.bat
exit /b 6


rem ---------------------------------------------------------------------------------------------
:success
echo    ========================================
echo    Clean up environment  at the end ...
echo    ========================================
taskkill /f /im cmake.exe  2>NUL
taskkill /f /im msbuild.exe 2>NUL
taskkill /f /im git.exe 2>NUL
taskkill /f /im cl.exe 2>NUL
taskkill /f /im lib.exe 2>NUL
taskkill /f /im link.exe 2>NUL
taskkill /f /im git-remote-https.exe 2>NUL
taskkill /f /im vctip.exe 2>NUL
taskkill /f /im cvtres.exe 2>NUL
taskkill /f /im rc.exe 2>NUL
call paddle_winci\Scripts\deactivate.bat
echo Windows CI run successfully!
exit /b 0

ENDLOCAL
