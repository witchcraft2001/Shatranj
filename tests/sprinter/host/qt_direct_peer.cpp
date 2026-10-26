// Real Qt Direct adapter over TCP, for the Sprinter/MAME acceptance run.
#include "pc/client/direct_session_adapter.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QThread>
#include <QTcpSocket>
#include <QTcpServer>
#include <cstdio>
#include <array>
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    const int guests = argc > 2 ? QString(argv[2]).toInt() : 1;
    const bool hostBlack = argc > 3 && QString(argv[3]) == "black";
    const bool asHost = argc > 4 && QString(argv[4]) == "host";
    const bool sendMove = asHost || hostBlack;
    for (int guest = 0; guest < guests; ++guest) {
    QTcpSocket client;
    QTcpServer server;
    QElapsedTimer clock; clock.start();
    const quint16 port = argc > 1 ? QString(argv[1]).toUShort() : 15000;
    if (asHost && (!server.listen(QHostAddress::LocalHost, port) || !server.waitForNewConnection(120000))) return 8;
    QTcpSocket &socket = asHost ? *server.nextPendingConnection() : client;
    while (!asHost && clock.elapsed() < 120000) {
        socket.connectToHost("127.0.0.1", port);
        if (socket.waitForConnected(200)) break;
        socket.abort(); QThread::msleep(200);
    }
    if (socket.state()!=QAbstractSocket::ConnectedState) return 2;
    DirectSessionAdapter adapter;
    if (!adapter.init(asHost ? SESSION_ROLE_HOST : SESSION_ROLE_GUEST,SESSION_COLOR_WHITE)) return 3;
    adapter.enqueueLinkUp(1);
    std::array<qint64,SESSION_TIMER_COUNT> timers{};
    bool started=false, moveAck=false, duplicateSent=false;
    qint64 moveAt = 0;
    qint64 end=clock.elapsed()+25000;
    while(clock.elapsed()<end) {
        DirectActionBatch batch;
        while(adapter.takeNextBatch(&batch)) {
            for(uint8_t i=0;i<batch.count;++i) {
                const auto &owned=batch.actions[i]; const auto &a=owned.action;
                if(a.type==SESSION_ACT_SEND) {
                    printf("TX %s\n",owned.payload.constData());fflush(stdout);
                    socket.write(owned.payload+"\n");socket.flush();
                    adapter.enqueueTxResult(a.data.send.tx_id,SESSION_TX_OK);
                } else if(a.type==SESSION_ACT_TIMER_SET) {
                    timers[a.data.timer_set.timer_id]=clock.elapsed()+20*a.data.timer_set.duration_ticks;
                } else if(a.type==SESSION_ACT_TIMER_CANCEL) {
                    timers[a.data.timer_cancel.timer_id]=0;
                } else if(a.type==SESSION_ACT_SESSION_CHANGED) {
                    printf("SESSION %u\n",a.data.session.status);fflush(stdout);
                    if(asHost && a.data.session.status==SESSION_CHANGED_READY) adapter.enqueueLocalRequest(SESSION_REQUEST_START);
                    if(a.data.session.status==SESSION_CHANGED_STARTED) {
                        started=true;end=clock.elapsed()+(sendMove ? 25000 : 4000);
                        if(sendMove) moveAt = clock.elapsed() + (argc > 5 ? QString(argv[5]).toInt() : 0);
                    }
                    if(a.data.session.status==SESSION_CHANGED_ENDED && !started)return 4;
                }
            }
        }
        if(moveAt && clock.elapsed() >= moveAt) {
            moveAt = 0;
            adapter.enqueueLocalRequest(SESSION_REQUEST_MOVE, 0u, "e2e4");
        }
        socket.waitForReadyRead(20);
        while(socket.canReadLine()) {
            QByteArray line=socket.readLine().trimmed();
            printf("RX %s\n",line.constData());fflush(stdout);
            if(line.startsWith("HELLO DIRECT HOST WHITE=")) {
                if(line != (hostBlack ? "HELLO DIRECT HOST WHITE=GUEST" : "HELLO DIRECT HOST WHITE=HOST")) return 6;
            }
            if(line.startsWith("ACK 1 ")) {moveAck=true;end=clock.elapsed()+1000;}
            if(!asHost && moveAck && !duplicateSent) {
                // A repeat HELLO after a move must neither reset nor re-handshake.
                socket.write("HELLO DIRECT GUEST\n");socket.flush();duplicateSent=true;
            } else if(duplicateSent && line.startsWith("HELLO ")) return 7;
            adapter.enqueueRx(1,line);
        }
        for(uint8_t i=0;i<SESSION_TIMER_COUNT;++i)if(timers[i] && clock.elapsed()>=timers[i]) {
            timers[i]=0;adapter.enqueueTimeout(i);
        }
    }
    if(guest % 2 == 0 && socket.state()==QAbstractSocket::ConnectedState) {
        socket.write("BYE\n");socket.flush();socket.waitForBytesWritten(1000);
    }
    socket.disconnectFromHost();
    printf("%s Qt guest handshake, START and optional first MOVE\n",started && (!sendMove || moveAck)?"PASS":"FAIL");
    if(!started || (sendMove && !moveAck)) return 5;
    QThread::msleep(1500);
    }
    return 0;
}
