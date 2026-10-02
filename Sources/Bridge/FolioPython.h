#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FolioProgressBlock)(double fraction, NSString *message);
typedef void (^FolioResultBlock)(NSString *json);

/// Runs the embedded Python interpreter (and yt-dlp) on one dedicated
/// background thread. All results are JSON strings delivered on the main queue.
@interface FolioPython : NSObject

@property (class, nonatomic, readonly) FolioPython *shared;

/// Starts Python (if needed) and returns {"ok":true,"version":"…"}.
- (void)prepare:(FolioResultBlock)completion NS_SWIFT_NAME(prepare(completion:));

/// Downloads the audio of `url` into `directory`.
- (void)downloadURL:(NSString *)url
        toDirectory:(NSString *)directory
           progress:(FolioProgressBlock)progress
         completion:(FolioResultBlock)completion NS_SWIFT_NAME(download(url:to:progress:completion:));

/// Fetches the newest yt-dlp from PyPI (used from the next launch on).
- (void)updateWithProgress:(FolioProgressBlock)progress
                completion:(FolioResultBlock)completion NS_SWIFT_NAME(update(progress:completion:));

/// Deletes downloaded updates (back to the bundled yt-dlp on next launch).
- (void)resetUpdates:(FolioResultBlock)completion NS_SWIFT_NAME(resetUpdates(completion:));

/// Asks the running download to stop.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
