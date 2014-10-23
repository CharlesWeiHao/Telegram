#import "TGInstagramThumbnailDataSource.h"

#import "ASQueue.h"

#import "TGWorkerPool.h"
#import "TGWorkerTask.h"
#import "TGMediaPreviewTask.h"

#import "TGMemoryImageCache.h"

#import "TGImageUtils.h"
#import "TGStringUtils.h"
#import "TGRemoteImageView.h"

#import "TGImageBlur.h"
#import "UIImage+TG.h"
#import "NSObject+TGLock.h"

#import "TGMediaStoreContext.h"

static TGWorkerPool *workerPool()
{
    static TGWorkerPool *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        instance = [[TGWorkerPool alloc] init];
    });
    
    return instance;
}

static ASQueue *taskManagementQueue()
{
    static ASQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        queue = [[ASQueue alloc] initWithName:"org.telegram.instagramThumbnailTaskManagementQueue"];
    });
    
    return queue;
}

@implementation TGInstagramThumbnailDataSource

+ (void)load
{
    @autoreleasepool
    {
        [TGImageDataSource registerDataSource:[[self alloc] init]];
    }
}

+ (NSString *)uriPrefix
{
    return @"instagram-preview://";
}

- (bool)canHandleUri:(NSString *)uri
{
    return [uri hasPrefix:[TGInstagramThumbnailDataSource uriPrefix]];
}

- (bool)canHandleAttributeUri:(NSString *)uri
{
    return [uri hasPrefix:[TGInstagramThumbnailDataSource uriPrefix]];
}

+ (NSString *)imageAddressForUri:(NSString *)uri size:(out CGSize *)size
{
    NSDictionary *args = [TGStringUtils argumentDictionaryInUrlString:[uri substringFromIndex:[[NSString alloc] initWithFormat:@"%@?", [TGInstagramThumbnailDataSource uriPrefix]].length]];
    
    CGSize imageSize = CGSizeMake([args[@"width"] intValue], [args[@"height"] intValue]);
    
    if (size != NULL)
        *size = imageSize;
    
    return args[@"url"] == nil ? nil : [[NSString alloc] initWithFormat:@"%@", args[@"url"]];
}

- (id)loadDataAsyncWithUri:(NSString *)uri progress:(void (^)(float))progress partialCompletion:(void (^)(TGDataResource *resource))__unused partialCompletion completion:(void (^)(TGDataResource *))completion
{
    if ([TGInstagramThumbnailDataSource imageAddressForUri:uri size:NULL] == nil)
    {
        if (completion)
            completion([TGInstagramThumbnailDataSource resultForUnavailableImage]);
        return nil;
    }
    
    TGMediaPreviewTask *previewTask = [[TGMediaPreviewTask alloc] init];
    
    [taskManagementQueue() dispatchOnQueue:^
    {
        TGWorkerTask *workerTask = [[TGWorkerTask alloc] initWithBlock:^(bool (^isCancelled)())
        {
            TGDataResource *result = [TGInstagramThumbnailDataSource _performLoad:uri isCancelled:isCancelled];
            
            if (result != nil && progress != nil)
                progress(1.0f);
            
            if (isCancelled != nil && isCancelled())
                return;
            
            if (completion != nil)
                completion(result != nil ? result : [TGInstagramThumbnailDataSource resultForUnavailableImage]);
        }];
        
        if ([TGInstagramThumbnailDataSource _isDataLocallyAvailableForUri:uri])
        {
            [previewTask executeWithWorkerTask:workerTask workerPool:workerPool()];
        }
        else
        {
            [previewTask executeWithTargetFilePath:nil uri:[TGInstagramThumbnailDataSource imageAddressForUri:uri size:NULL] completion:^(bool success)
            {
                if (success)
                {
                    dispatch_async([TGCache diskCacheQueue], ^
                    {
                        [previewTask executeWithWorkerTask:workerTask workerPool:workerPool()];
                    });
                }
                else
                {
                    if (completion != nil)
                        completion([TGInstagramThumbnailDataSource resultForUnavailableImage]);
                }
            } workerTask:workerTask];
        }
    }];
    
    return previewTask;
}

- (void)cancelTaskById:(id)taskId
{
    [taskManagementQueue() dispatchOnQueue:^
    {
        if ([taskId isKindOfClass:[TGMediaPreviewTask class]])
        {
            TGMediaPreviewTask *previewTask = taskId;
            [previewTask cancel];
        }
    }];
}

+ (TGDataResource *)resultForUnavailableImage
{
    static TGDataResource *imageData = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        imageData = [[TGDataResource alloc] initWithImage:TGAverageColorAttachmentImage([UIColor darkGrayColor]) decoded:true];
    });
    
    return imageData;
}

- (id)loadAttributeSyncForUri:(NSString *)__unused uri attribute:(NSString *)attribute
{
    if ([attribute isEqualToString:@"placeholder"])
    {
        static UIImage *placeholder = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^
        {
            placeholder = TGAverageColorAttachmentImage([UIColor whiteColor]);
        });
        
        return placeholder;
    }
    
    return nil;
}

- (TGDataResource *)loadDataSyncWithUri:(NSString *)uri canWait:(bool)canWait acceptPartialData:(bool)__unused acceptPartialData asyncTaskId:(__autoreleasing id *)__unused asyncTaskId progress:(void (^)(float))__unused progress partialCompletion:(void (^)(TGDataResource *))__unused partialCompletion completion:(void (^)(TGDataResource *))__unused completion
{
    if (uri == nil)
        return nil;
    
    if ([TGInstagramThumbnailDataSource imageAddressForUri:uri size:NULL] == nil)
        return [TGInstagramThumbnailDataSource resultForUnavailableImage];
    
    UIImage *cachedImage = [[TGMediaStoreContext instance] mediaImage:uri attributes:nil];
    if (cachedImage != nil)
        return [[TGDataResource alloc] initWithImage:cachedImage decoded:true];
    
    if (!canWait)
        return nil;
    
    return [TGInstagramThumbnailDataSource _performLoad:uri isCancelled:nil];
}

+ (bool)_isDataLocallyAvailableForUri:(NSString *)uri
{
    NSString *mapAddress = [self imageAddressForUri:uri size:NULL];
    
    NSString *filePath = [[TGRemoteImageView sharedCache] pathForCachedData:mapAddress];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath])
        return true;
    
    return false;
}

+ (TGDataResource *)_performLoad:(NSString *)uri isCancelled:(bool (^)())isCancelled
{
    if (isCancelled && isCancelled())
        return nil;
    
    static NSString *filesDirectory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        filesDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, true)[0] stringByAppendingPathComponent:@"files"];
    });
    
    CGSize size = CGSizeZero;
    NSString *thumbnailPath = [[TGRemoteImageView sharedCache] pathForCachedData:[TGInstagramThumbnailDataSource imageAddressForUri:uri size:&size]];
    
    UIImage *thumbnailSourceImage = [[UIImage alloc] initWithContentsOfFile:thumbnailPath];
    
    UIGraphicsBeginImageContextWithOptions(size, true, 0.0f);
    
    CGSize drawingSize = TGFitSize(thumbnailSourceImage.size, size);
    if (drawingSize.width < size.width)
    {
        drawingSize.height = drawingSize.height * size.width / drawingSize.width;
        drawingSize.width = size.width;
    }
    
    CGRect imageRect = CGRectMake((size.width - drawingSize.width) / 2.0f, (size.height - drawingSize.height) / 2.0f, drawingSize.width, drawingSize.height);
    [thumbnailSourceImage drawInRect:imageRect blendMode:kCGBlendModeCopy alpha:1.0f];
    
    thumbnailSourceImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (thumbnailSourceImage != nil)
    {
        UIImage *thumbnailImage = nil;
        
        NSNumber *averageColor = [[TGMediaStoreContext instance] mediaImageAverageColor:uri];
        bool needsAverageColor = averageColor == nil;
        uint32_t averageColorValue = [averageColor intValue];
        
        thumbnailImage = TGLoadedAttachmentImage(thumbnailSourceImage, size, needsAverageColor ? &averageColorValue : NULL);
        
        if (thumbnailImage != nil)
        {
            [[TGMediaStoreContext instance] setMediaImageAverageColorForKey:uri averageColor:@(averageColorValue)];
            [[TGMediaStoreContext instance] setMediaImageForKey:uri image:thumbnailImage attributes:@{}];
            
            return [[TGDataResource alloc] initWithImage:thumbnailImage decoded:true];
        }
    }
    
    return nil;
}

@end
