#ifndef TAVERN_CLIENT_H
#define TAVERN_CLIENT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1. Все UTF-8 buffers borrowed до event_free; не NUL-terminated.
 * Ошибки и ответы public_json/config_json NUL-terminated owned: tavern_string_free.
 * Один next_event reader; send_json допускает другие потоки. open/send/public_json
 * блокирующие с конечными сроками: вызывайте вне main UI queue.
 * close thread-safe, прерывает IO. free ТОЛЬКО после окончания всех C вызовов.
 * Нельзя использовать client после free; event независим от client. */
typedef struct TavernClient TavernClient;
typedef struct TavernEvent TavernEvent;
typedef struct TavernTitleFeed TavernTitleFeed;
typedef struct { const uint8_t *ptr; size_t len; } TavernBytes;
typedef struct { uint16_t x, y; size_t count; uint8_t target; } TavernSegment;
/* target 0: main grid; target 1: popup grid (full only, own width/height). */
typedef struct {
    TavernBytes symbol;
    uint32_t fg, bg;
    uint16_t modifier;
    uint8_t skip, hyperlink_present;
    uint32_t hyperlink;
} TavernCell;
typedef struct {
    TavernBytes id, data;
    uint32_t width, height, format; /* 0 RGB, 1 RGBA, 2 PNG */
} TavernAsset;
enum { TAVERN_SNAPSHOT=1, TAVERN_FULL=2, TAVERN_PATCH=3,
       TAVERN_RESPONSE=4, TAVERN_NOTICE=5, TAVERN_ERROR=6, TAVERN_CLOSED=7 };
/* Process-wide diagnostic language: 0 English (default), 1 Russian.
 * Thread-safe; does not change the wire protocol or terminal content. */
void tavern_set_language(uint32_t language);
TavernClient *tavern_client_open(const char *socket_path, uint16_t cols, uint16_t rows,
    uint32_t cell_width_px, uint32_t cell_height_px, char **error);
void tavern_client_close(TavernClient *client);
void tavern_client_free(TavernClient *client);
/* 1 event, 0 timeout, 2 EOF (queue drained), -1 invalid argument/internal failure.
 * Runtime failures appear as ERROR followed by CLOSED; rejected method replies
 * remain RESPONSE with response.error. timeout_ms capped at 60000. */
int32_t tavern_client_next_event(TavernClient *client, uint32_t timeout_ms,
    TavernEvent **event, char **error);
/* 0 success, -1 failure. No automatic retry, including ambiguous partial writes.
 * <=1 MiB JSON commands:
 * {type:resize,cols,rows,cell_width_px,cell_height_px}
 * {type:text|paste,pane_id,text}; popup uses terminal_id instead of pane_id.
 * {type:key,pane_id,key,modifiers,kind}; kind press=0/repeat=1/release=2.
 * modifiers shift=1,control=2,alt=4,super=8,hyper=16,meta=32.
 * {type:mouse,pane_id,phase,col,row,button,modifiers,lines}
 * phase down/up/drag/move/upward/downward/leftward/rightward.
 * {type:request,request_id,boot_id,method,params}; one request in flight, 15s deadline.
 * {type:active,request_id,boot_id,active} -> client_shell.surface.set.
 * {type:focus,focused} -> host focus, not pane navigation.
 * Snapshot event JSON is raw projection. Full/patch JSON is grid-free metadata.
 * Response JSON: {boot_id,request_id,response:{id,result|error}}.
 * Notice JSON includes type. Unknown optional named controls are notices.
 */
int32_t tavern_client_send_json(TavernClient *client, const uint8_t *json, size_t len, char **error);
uint32_t tavern_event_kind(const TavernEvent *event);
TavernBytes tavern_event_json(const TavernEvent *event);
size_t tavern_event_segment_count(const TavernEvent *event);
int32_t tavern_event_segment(const TavernEvent *event, size_t index, TavernSegment *out);
int32_t tavern_event_cell(const TavernEvent *event, size_t segment, size_t index, TavernCell *out);
size_t tavern_event_asset_count(const TavernEvent *event);
int32_t tavern_event_asset(const TavernEvent *event, size_t index, TavernAsset *out);
void tavern_event_free(TavernEvent *event);
/* Public newline JSON API (herdr.sock), one bounded request, never retried.
 * Raw {id,method,params}; response id checked; rejection returned intact.
 * 0 success (including server response.error), -1 transport/protocol failure. */
int32_t tavern_public_json(const char *socket_path, const uint8_t *json, size_t len,
    char **response, char **error);
/* Public events.subscribe stream for pane.updated and pane.closed only.
 * open waits for subscription_started (connect <=10s, handshake <=15s); off-main.
 * next: 1 owned NUL-terminated JSON, 0 timeout, 2 EOF/closed, -1 failure.
 * JSON/errors: tavern_string_free. On non-event returns *json=NULL.
 * timeout_ms capped at 60000; 0 reads buffered/immediately available data.
 * Lines <=1 MiB; partial/coalesced lines retained across next calls.
 * One next reader. close is thread-safe and interrupts next without sending
 * session commands. free ONLY after all C calls finish. No automatic retries. */
TavernTitleFeed *tavern_title_feed_open(const char *socket_path, char **error);
int32_t tavern_title_feed_next(TavernTitleFeed *feed, uint32_t timeout_ms,
    char **json, char **error);
void tavern_title_feed_close(TavernTitleFeed *feed);
void tavern_title_feed_free(TavernTitleFeed *feed);
/* Чистое чтение/редактирование TOML без IO; JSON-запрос <=1 MiB:
 * {content: String, edit?: {kind: theme|indicators|sound|toast, value: String|Bool}}.
 * Ответ: {content: String, settings: {theme: String, auto_switch: Bool,
 * indicators: String, sound: Bool, toast: String}}.
 * Без edit исходный content не меняется. Тема выключает auto_switch;
 * toast удаляет устаревший ui.toast.enabled. Остальные поля/комментарии сохранены.
 * 0 — успех, -1 — ошибка; при ошибке response=NULL. Строки освобождает вызывающий. */
int32_t tavern_config_json(const uint8_t *json, size_t len, char **response, char **error);
void tavern_string_free(char *string);
#ifdef __cplusplus
}
#endif
#endif
