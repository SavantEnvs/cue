package config

import (
	"strings"
	"list"
)

#Port: int & >0 & <65536

server: {
	host: string | *"localhost"
	port: #Port | *8080
	tags: [...string]
	tags: list.UniqueItems
}

server: host: strings.ToLower("EXAMPLE.com")
