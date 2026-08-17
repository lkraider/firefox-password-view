/* Resource ids shared by win/app.rc and win/src/ids.zig. The test in
   ids.zig parses this file and compares every value, so a change here
   fails the build until ids.zig follows. */

#define IDI_APP 1
#define IDR_MAINMENU 2
#define IDR_ROWMENU 3
#define IDR_MAINACCEL 4
#define IDD_PASSWORD 5

#define IDM_FILE_EXIT 100
#define IDM_HELP_ABOUT 101
#define IDM_ROW_REVEAL 102
#define IDM_ROW_COPY 103
#define IDM_EDIT_FIND 104
#define IDM_EDIT_HIDE 105

#define IDC_SEARCH 1000
#define IDC_LIST 1001
#define IDC_STATUS 1002

#define IDC_PW_PROMPT 1010
#define IDC_PW_EDIT 1011
#define IDC_PW_ERROR 1012
