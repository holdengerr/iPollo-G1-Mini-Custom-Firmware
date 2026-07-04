#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
#define I2C_SLAVE 0x0703
#define MCU_SLAVE 0x7e
static int wf(int fd,const unsigned char*b,size_t l){size_t d=0;while(d<l){ssize_t n=write(fd,b+d,l-d);if(n<0){if(errno==EINTR)continue;return-1;}if(!n)return-1;d+=n;}return 0;}
static int rf(int fd,unsigned char*b,size_t l){size_t d=0;while(d<l){ssize_t n=read(fd,b+d,l-d);if(n<0){if(errno==EINTR)continue;return-1;}if(!n)return-1;d+=n;}return 0;}
static int rd(int fd,uint32_t reg,uint32_t*v){unsigned char a[4]={(unsigned char)(reg>>24),(unsigned char)(reg>>16),(unsigned char)(reg>>8),(unsigned char)reg},b[4]; if(wf(fd,a,4)||rf(fd,b,4))return-1; *v=((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3]; return 0;}
static int wr(int fd,uint32_t reg,uint32_t val){unsigned char b[8]={(unsigned char)(reg>>24),(unsigned char)(reg>>16),(unsigned char)(reg>>8),(unsigned char)reg,(unsigned char)(val>>24),(unsigned char)(val>>16),(unsigned char)(val>>8),(unsigned char)val}; ssize_t n=write(fd,b,8); return (n==8||errno==ENXIO)?0:-1;}
static void msleep(unsigned ms){usleep(ms*1000);} 
static int sane_mv(int v){return v>0 && v<5000;}
static int sane_current_raw(int v){return v>=0 && v<5000;}
static int sane_power_w(int v){return v>=0 && v<1000;}
static int read_word(int fd,uint8_t dev,uint8_t reg,int *val){uint32_t d0=0,cmd=((uint32_t)dev<<24)|(1u<<16)|((uint32_t)reg<<8)|2; if(val)*val=-1; if(wr(fd,0x4f000260,0)||wr(fd,0x4f000264,0)||wr(fd,0x4f000268,cmd))return-1; msleep(250); if(rd(fd,0x4f000260,&d0))return-1; {int word=(int)(((d0>>24)&0xff)|((d0>>8)&0xff00)); if(word==0 || word==0xffff) return -1; if(val)*val=word;} return 0;}
static void write_json(const char*out,int ok,int core_v,int ddr_v,int i,int p,int vin,int pin,const char*core_dev,const char*ddr_dev){
char tmp[160];snprintf(tmp,sizeof(tmp),"%s.tmp",out);FILE*f=fopen(tmp,"w");if(!f)return;
fprintf(f,"{\"updated_epoch\":%ld,\"ok\":%s,\"source\":\"mcu-bridge-pmbus\",",(long)time(NULL),ok?"true":"false");
if(!ok)fprintf(f,"\"error\":\"no_pmbus_values\",");
fprintf(f,"\"rails\":{\"ddr\":{\"dev\":\"%s\",\"vout_mv\":%d,\"iout_raw\":-1,\"iout_a\":-1.0,\"pout_w\":-1},",ddr_dev?ddr_dev:"profile",ddr_v);
fprintf(f,"\"core\":{\"dev\":\"%s\",\"vout_mv\":%d,\"iout_raw\":%d,\"iout_a\":%.1f,\"pout_w\":%d,\"vin_mv\":%d,\"pin_w\":%d}}}\n",core_dev?core_dev:"0xc0-active-page",core_v,i,i>=0?i/10.0:-1.0,p,vin,pin);
fclose(f);rename(tmp,out);}
int main(int argc,char**argv){const char*out="/tmp/g1-rail-telemetry.json";int interval=30,once=0;for(int a=1;a<argc;a++){if(!strcmp(argv[a],"--once"))once=1;else if(!strcmp(argv[a],"--output")&&a+1<argc)out=argv[++a];else if(!strcmp(argv[a],"--interval")&&a+1<argc)interval=atoi(argv[++a]);}if(interval<10)interval=10;do{int fd=open("/dev/i2c-0",O_RDWR);int core_v=-1,ddr_v=-1,i=-1,p=-1,vin=-1,pin=-1,ok=0;const char*core_dev="0xc0-active-page";const char*ddr_dev="profile";if(fd>=0&&ioctl(fd,I2C_SLAVE,MCU_SLAVE)==0){
read_word(fd,0xc0,0x8b,&core_v);read_word(fd,0xc0,0x8c,&i);read_word(fd,0xc0,0x96,&p);read_word(fd,0xc0,0x88,&vin);read_word(fd,0xc0,0x97,&pin);
if(!sane_mv(core_v)){int raw=-1;if(read_word(fd,0x60,0x21,&raw)==0 && raw>0 && raw<2500){core_v=raw*2;core_dev="0x60-active-mini";}}
{int raw=-1;if(read_word(fd,0x62,0x21,&raw)==0 && raw>0 && raw<2500){ddr_v=raw*2;ddr_dev="0x62-active-mini";}}
if(!sane_mv(core_v))core_v=-1; if(!sane_mv(ddr_v))ddr_v=-1; if(!sane_current_raw(i))i=-1; if(!sane_power_w(p))p=-1; if(!sane_mv(vin))vin=-1; if(!sane_power_w(pin))pin=-1; ok=(core_v>=0||ddr_v>=0||i>=0||p>=0||vin>=0||pin>=0);close(fd);}write_json(out,ok,core_v,ddr_v,i,p,vin,pin,core_dev,ddr_dev);if(!once)sleep(interval);}while(!once);return 0;}



