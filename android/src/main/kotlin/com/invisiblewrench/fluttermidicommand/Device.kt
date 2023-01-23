package com.invisiblewrench.fluttermidicommand

abstract class Device {
    var id:String
    var type:String
    var name:String

    protected var setupStreamHandler: FMCStreamHandler? = null

    constructor(id: String, type: String, name: String) {
        this.id = id
        this.type = type
        this.name = name;
    }

    abstract fun send(data: ByteArray, timestamp: Long?)

    abstract fun close()


}
