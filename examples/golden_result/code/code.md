WebLogic Workbook for *Enterprise JavaBeans, 3rd Edition*

***

relationship between the beans. The only difference from previous exercises is the change in the
JNDI name element tag for the `Address` home interface:

```xml
      <local-jndi-name>AddressHomeLocal</local-jndi-name>
```

Because the `Home` interface for the `Address` is local, the tag is `<local-jndi-name>` rather than
`<jndi-name>`.

The *weblogic-cmp-rdbms-jar.xml* descriptor file contains a number of new sections and elements
in this exercise. A detailed examination of the relationship elements will wait until the next
exercise, but there are some other changes to observe and examine.

The file contains a section mapping the `Address` `<cmp-field>` attributes from the *ejb-jar.xml*
file to the database columns in the `ADDRESS` table, in addition to a new section related to the
automatic key generation used for primary key values in this bean:

```xml
   <weblogic-rdbms-bean>
      <ejb-name>AddressEJB</ejb-name>
      <data-source-name>titan-dataSource</data-source-name>
      <table-name>ADDRESS</table-name>
      <field-map>
         <cmp-field>id</cmp-field>
         <dbms-column>ID</dbms-column>
      </field-map>
      <field-map>
         <cmp-field>street</cmp-field>
         <dbms-column>STREET</dbms-column>
      </field-map>
      <field-map>
         <cmp-field>city</cmp-field>
         <dbms-column>CITY</dbms-column>
      </field-map>
      <field-map>
         <cmp-field>state</cmp-field>
         <dbms-column>STATE</dbms-column>
      </field-map>
      <field-map>
         <cmp-field>zip</cmp-field>
         <dbms-column>ZIP</dbms-column>
      </field-map>
      <!-- Automatically generate the value of ID in the database on
      inserts using sequence table -->
      <automatic-key-generation>
         <generator-type>NAMED_SEQUENCE_TABLE</generator-type>
         <generator-name>ADDRESS_SEQUENCE</generator-name>
         <key-cache-size>10</key-cache-size>
      </automatic-key-generation>
   </weblogic-rdbms-bean>
```

96 &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Buy the printed version of this book at *http://www.titan-books.com*
