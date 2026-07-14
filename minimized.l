/*
<http://www.gnu.org/licenses/>.  */
%{
%}
HWS	[ \t\r\v\f]
EOID	[^[:alnum:]_]
%x in_struct i
%%
<INITIAL>{
^{HWS}typedef/{EOID} {
}
}
