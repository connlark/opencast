enum UpNextQueuePopResult {
    case item(UpNextQueueItem)
    case empty
    case failure(String)
}
