/* Exercise the shipped NET screen and handshake against a scripted uNet.
 * Framing, port validation, configuration and Direct HELLO parsing are real. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define SPRINTER_HOST_TEST 1
#define __z88dk_fastcall
#include "../../../src/sprinter/net_ui_sprinter.c"
#include "../../session/direct_parity.h"

direct_host_state_t direct_host;
unsigned char net_active, key_code, ng_up_reason, ng_v_call_status, ng_v_call_cf;
unsigned char frame_counter;
unsigned char ng_v_last_cf, ng_v_last_nerr, ng_start_status;
uint16_t ng_caps, ng_v_call_len, ng_v_call_flags;
char ng_dll_name[16]="UNETRTL", ng_buf_lasterr[64], ng_buf_ip[16]="10.0.0.2";
char *ng_c_connect_host, *ng_c_connect_port, *ng_c_env_name, *ng_c_env_dest;
unsigned char ng_c_env_capacity, ng_c_env_found;
unsigned char net_mqtt_fail_step, net_mqtt_fail_cf, net_mqtt_fail_status;
static char payload[48], wire[48], first_wire[48], calls[256];
static char sent_wire[16][48];
static unsigned call_count, pumps, sends, drops, listen_calls, sessions, pauses, resumes;
static int cancel, listen_error, status_error, recv_error, split, recv_lost, failure_shown, retry_once;
static unsigned cancel_after_listens;
static const char *env_port;
static unsigned frames;
static void trace(char c) { assert(call_count < 255); calls[call_count++]=c; calls[call_count]=0; }
void host_rx_pause(void) {++pauses;}
void host_rx_resume(void) {++resumes;}
void ng_shutdown(void) {trace('X');}
void ng_up(void) { trace('B'); }
void ng_close(void) { trace('C'); }
void ng_lasterr_fetch(void) {}
void ng_getinfo_ip(void) {}
void host_listen(uint16_t port) { assert(port==direct_host.port); trace('L'); ++listen_calls; ng_v_call_cf=0; ng_v_call_status=listen_error; }
void host_unlisten(void) { trace('U'); ng_v_call_cf=ng_v_call_status=0; }
void host_status(void) { trace('S'); ng_v_call_status=status_error; ng_v_call_len=split && pumps==1 ? 1 : 10; }
void ng_c_connect_at(void) { trace('J'); ng_v_call_cf=ng_v_call_status=0; }
void ng_c_env_get(void) {
    ng_c_env_found=0;
    if (env_port && !strcmp(ng_c_env_name,"NETPORT")) {
        net_ui_copy_capped(ng_c_env_dest,ng_c_env_capacity,env_port);
        ng_c_env_found=strlen(env_port)>=ng_c_env_capacity ? 2 : 1;
    }
}
void frame_wait(void) { assert(++frames < 10000); ++frame_counter; }
void key_poll(void) {
    if(failure_shown && retry_once) {
        retry_once=listen_error=status_error=failure_shown=0;key_code=NET_UI_KEY_ENTER;return;
    }
    if (cancel || (cancel_after_listens && listen_calls >= cancel_after_listens) ||
        failure_shown || !(ng_caps&32)) key_code=0x8a; }
void spectrum_render_fileui_frame(void) {}
void spectrum_render_ikkle_at(const char *s) { assert(strlen(s+3)<56); if(strstr(s+3,"FAILED"))failure_shown=1; }
void spectrum_gui_clear_cursor_coords(void) {}
void spectrum_gui_restore_board_area(void) {}
void saveload_full_redraw(void) {}
void spectrum_gui_notify(const char *s, uint8_t e) { (void)s;(void)e; }
void spectrum_gui_notify_persistent(const char *s) {(void)s;}
void spectrum_gui_set_connected(uint8_t c) {(void)c;}
void spectrum_gui_set_status(const char *s) {(void)s;}
unsigned char net_mqtt_connect_start_ovl(void) {return 1;}
unsigned char net_preflight_ovl(void) {return 1;}
uint16_t net_mqtt_new_session_id(void) {return 1;}
void spectrum_net_start_uart(void) {trace('I'); nc_init();}
char *spectrum_net_payload_scratch(void) {return payload;}
void spectrum_net_direct_peer_mark_valid(void) {}
uint8_t spectrum_net_send_text(const char *s) {
    assert(sends<16);strcpy(sent_wire[sends],s);
    if (!sends)strcpy(first_wire,s);
    ++sends; strcpy(wire,s);return 1;
}
void net_session_begin(void) {net_peer_known=1;++sessions;}
void net_drop(const char *s) {(void)s;++drops;net_active=0;}
uint8_t netchesszx_session_peer_ready_state;
void netchesszx_session_peer_reset(void) {netchesszx_session_peer_ready_state=0;}
void netchesszx_session_peer_mark_ready(void) {netchesszx_session_peer_ready_state=1;}
uint16_t ng_c_recv_max;
uint8_t ng_buf_rx[255];
void ng_c_recv_poll(void) {
    const char *s="HELLO DIRECT GUEST\nMOVE 1 e2e4\n";
    ++pumps; trace('R');
    if(split) s=pumps==1 ? "HELLO DIRE" : "CT GUEST\nMOVE 1 e2e4\n";
    strcpy((char *)ng_buf_rx,s);
    ng_v_call_len=(uint16_t)strlen(s);
    ng_v_call_status=recv_error;ng_v_call_flags=recv_lost ? 4 : 0;
    recv_error=recv_lost=0;
}
static void reset(void) {
    memset(&direct_host,0,sizeof(direct_host));
    frame_counter=0;
    ng_caps=32;ng_up_reason=0;ng_v_call_cf=ng_v_call_status=0;
    frames=call_count=pumps=sends=drops=listen_calls=sessions=pauses=resumes=0;calls[0]=0;
    cancel=listen_error=status_error=recv_error=split=recv_lost=failure_shown=retry_once=0;env_port=0;cancel_after_listens=0;
    net_ui_fields_seeded=0; net_ui_transport=0;net_ui_role=0;net_ui_color=0;
    net_ui_seed_fields();
}
/* The common transcript runner is the oracle: no Sprinter-specific expected
 * wire values. Auto-START is an application request after HELLO readiness. */
static void check_reference_handshake(unsigned color, unsigned host) {
    DirectParityScenario scenario = host ? direct_parity_start_host : direct_parity_guest_smoke;
    DirectParityStep steps[6];
    DirectParityTrace trace;
    unsigned i, send=0, started=0;
    unsigned count = host ? 4 : 2;
    memcpy(steps,scenario.steps,count*sizeof(steps[0]));
    steps[count]=steps[1]; /* repeat HELLO after START/READY */
    steps[count+1]=steps[1];
    steps[count+1].payload=(const uint8_t *)(host ? "GAME START WHITE=HOST" : "GAME START WHITE=BAD");
    steps[count+1].length=(uint8_t)strlen((const char *)steps[count+1].payload);
    scenario.steps=steps;scenario.step_count=(uint8_t)(count+2);
    scenario.host_color=(uint8_t)color;
    assert(direct_reference_run(&scenario,&trace));
    reset();netchesszx_session_configure(host ? 0 : 1,0,(uint8_t)color);
    if(!host)netchesszx_host_color_ready=0;
    net_prepare_ovl();assert(net_hello_tick_ovl());
    strcpy(payload,(const char *)steps[1].payload);assert(net_hello_ovl()==1);
    if(host) {strcpy(payload,"ACK GAME START");assert(net_hello_ovl()==1);}
    strcpy(payload,(const char *)steps[1].payload);assert(net_hello_ovl()==1);
    assert(sessions==1);
    strcpy(payload,(const char *)steps[count+1].payload);assert(net_hello_ovl()==1);
    for(i=0;i<trace.count;++i) {
        const DirectParityObservation *o=&trace.observations[i];
        if(o->type==DIRECT_PARITY_OBS_SEND) {
            assert(send<sends);assert(!strcmp(o->payload,sent_wire[send++]));
        }
        if(o->type==DIRECT_PARITY_OBS_STARTED)++started;
    }
    assert(send==sends);assert(started==host);
}
int main(void) {
    char *field; uint8_t cap; char (*filter)(char);unsigned color,i;
    reset();assert(!strcmp(net_ui_field_dport,"5000"));
    env_port="1a";net_ui_fields_seeded=0;net_ui_seed_fields();assert(!net_ui_port_value(net_ui_field_dport,&direct_host.port));
    env_port="65536";net_ui_fields_seeded=0;net_ui_seed_fields();assert(!net_ui_port_value(net_ui_field_dport,&direct_host.port));
    env_port="123456";net_ui_fields_seeded=0;net_ui_seed_fields();assert(net_ui_field_dport[0]==0);
    for(color=0;color<2;++color) {
        reset();net_ui_color=color;split=color;
        net_ui_focus=1;net_ui_focus_normalize(1);assert(net_ui_focus==1);
        net_ui_focus=2;assert(!net_ui_focused_field(&field,&cap,&filter));
        strcpy(net_ui_field_host,"bad address");
        assert(net_ui_try_connect());assert(direct_host.enabled);assert(netchesszx_local_color==color);
        assert(strstr(calls,"ICL"));assert(calls[call_count-1]=='U');
        assert(sends==0);assert(nc_queue_count()==2);
        net_prepare_ovl();assert(nc_queue_count()==2);
        assert(nc_line_pop(payload,sizeof(payload))>0);assert(net_hello_ovl()==1);assert(sends==2);
        assert(strstr(first_wire,color ? "WHITE=GUEST" : "WHITE=HOST"));
        assert(net_hello_ovl()==1);assert(sends==2);
        assert(!net_peer_known);assert(direct_host.start_pending);
        strcpy(payload,"ACK GAME START");assert(net_hello_ovl()==1);
        assert(net_peer_known);assert(!direct_host.start_pending);assert(sessions==1);
        strcpy(payload,"HELLO DIRECT GUEST");assert(net_hello_ovl());assert(sessions==1);assert(sends==2);
        assert(pauses==2 && resumes==3);
        assert(nc_line_pop(payload,sizeof(payload))>0);assert(!strcmp(payload,"MOVE 1 e2e4"));
        strcpy(payload,"HELLO DIRECT HOST WHITE=HOST");assert(net_hello_ovl()==2);
        assert(!strcmp(payload,"Bad HELLO from opponent"));assert(drops==0);
        net_host_close_ovl();assert(calls[call_count-1]=='C');
        pumps=0;assert(net_host_wait_ovl());net_prepare_ovl();assert(!net_peer_known);assert(nc_queue_count()==2);
    }
    reset();net_ui_role=1;net_ui_focus=2;assert(net_ui_focused_field(&field,&cap,&filter));
    assert(net_ui_try_connect());assert(!direct_host.enabled);assert(strstr(calls,"IJ"));
    net_prepare_ovl();strcpy(payload,"HELLO DIRECT HOST WHITE=GUEST");assert(net_hello_ovl()==1);assert(netchesszx_local_is_white());
    for(i=0;i<4;++i) {
        reset();direct_host.enabled=1;direct_host.port=5000;
        if(i==0)ng_caps=0;
        if(i==1)cancel=1;
        if(i==2)listen_error=13;
        if(i==3)status_error=1;
        assert(!net_host_wait_ovl());assert(!direct_host.enabled);assert(sends==0);
        if(i)assert(!strcmp(calls+call_count-2,"UC"));else assert(listen_calls==0);
    }
    reset();direct_host.enabled=1;direct_host.port=5000;listen_error=13;retry_once=1;
    assert(net_host_wait_ovl());assert(direct_host.enabled);assert(listen_calls==2);
    reset();ng_caps=0;net_ui_role=1;assert(net_ui_try_connect()); /* JOIN does not require LISTEN */
    for (i=0;i<2;++i) {
        reset();direct_host.enabled=1;direct_host.port=5000;cancel_after_listens=2;
        if(i)recv_lost=1;else recv_error=7;
        assert(!net_host_wait_ovl());assert(!direct_host.enabled);
        assert(listen_calls==2);assert(pumps==1);assert(strstr(calls,"RUCBICLUC"));
        assert(nc_queue_count()==0); /* new attempt discarded the failed RX */
    }
    reset();netchesszx_session_configure(0,0,0);net_prepare_ovl();
    assert(net_hello_tick_ovl());assert(sends==1);
    net_ping.idle_ticks=74;
    for(i=0;i<200;++i)assert(net_hello_tick_ovl());
    assert(sends==1);assert(net_ping.idle_ticks==0); /* calls are not elapsed time */
    frame_counter=149;assert(net_hello_tick_ovl());assert(sends==1);
    frame_counter=150;assert(net_hello_tick_ovl());assert(sends==2);
    reset();netchesszx_session_configure(0,0,0);frame_counter=250;net_prepare_ovl();
    assert(net_hello_tick_ovl());frame_counter=144; /* wrap: 150 actual frames */
    assert(net_hello_tick_ovl());assert(sends==2);
    reset();netchesszx_session_configure(0,0,0);net_prepare_ovl();
    for(i=0;i<1000;++i) {++frame_counter;if(net_hello_tick_ovl()==2)break;}
    assert(i<1000);assert(drops==0);assert(!strcmp(payload,"Handshake failed"));
    assert(sends==SESSION_DIRECT_HELLO_RETRIES+2); /* HELLOs plus BYE */
    reset();netchesszx_session_configure(0,0,0);net_prepare_ovl();
    strcpy(payload,"HELLO DIRECT GUEST");assert(net_hello_ovl());
    for(i=0;i<1000;++i) {++frame_counter;if(net_hello_tick_ovl()==2)break;}
    assert(i<1000);assert(drops==0);
    assert(sends==SESSION_DIRECT_REPLY_RETRIES+3); /* HELLO + START/retries + BYE */
    check_reference_handshake(0,1);check_reference_handshake(1,1);
    check_reference_handshake(0,0);
    puts("[OK] Sprinter Direct HOST/JOIN UI, accept RX, cleanup and HELLO");
    return 0;
}
